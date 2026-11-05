-- Push notifications (branch push, not live yet). Standard Web Push: no
-- third-party service. Additive only.
--   * push_subscriptions: a browser/device that opted in (per user).
--   * notification_outbox: one row per user per event, sent by the push-send
--     edge function (pg_cron every minute, only when something is waiting).
--   * VAPID keys live in Vault; the edge function creates them on first run.
-- Events: new lead forwarded to the rep's firm, review finalized, question
-- answered (reps); new question from a rep (managers).
-- Trigger bodies never fail the original write: errors only raise a warning.

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_success_at timestamptz,
  disabled_at timestamptz
);
alter table public.push_subscriptions enable row level security;
create policy push_subscriptions_own on public.push_subscriptions for select using (user_id = (select auth.uid()));
grant select on public.push_subscriptions to authenticated;

create table if not exists public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid not null references auth.users(id),
  kind text not null,
  ref text not null,
  title text not null,
  body text,
  url text,
  sent_at timestamptz,
  delivered integer not null default 0,
  error text,
  unique (kind, ref, user_id)
);
alter table public.notification_outbox enable row level security;
create policy notification_outbox_manager_read on public.notification_outbox for select using (public.current_role_name() = 'manager');
grant select on public.notification_outbox to authenticated;
create index if not exists notification_outbox_unsent_idx on public.notification_outbox(created_at) where sent_at is null;

-- ---- subscriptions (from the browser) ----
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text)
returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'Invalid subscription'; end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth,
    user_agent = excluded.user_agent, disabled_at = null;
end; $function$;

create or replace function public.remove_push_subscription(p_endpoint text)
returns void language sql security definer set search_path to 'public' as $function$
  update public.push_subscriptions set disabled_at = now() where endpoint = p_endpoint and user_id = auth.uid();
$function$;

-- ---- VAPID keys in Vault ----
create or replace function public.push_public_key()
returns text language sql stable security definer set search_path to '' as $function$
  select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_public';
$function$;

create or replace function public.push_vapid_get()
returns table(public_key text, private_jwk text) language sql stable security definer set search_path to '' as $function$
  select (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_public'),
         (select decrypted_secret from vault.decrypted_secrets where name = 'push_vapid_private_jwk');
$function$;

create or replace function public.push_vapid_put(p_public text, p_private_jwk text)
returns void language plpgsql security definer set search_path to '' as $function$
begin
  if exists (select 1 from vault.secrets where name in ('push_vapid_public', 'push_vapid_private_jwk')) then return; end if;
  perform vault.create_secret(p_public, 'push_vapid_public', 'Web Push VAPID public key (AUDAC Rep Portal)');
  perform vault.create_secret(p_private_jwk, 'push_vapid_private_jwk', 'Web Push VAPID private key, JWK (AUDAC Rep Portal)');
end; $function$;

-- ---- queueing ----
create or replace function public.enqueue_notification(p_user uuid, p_kind text, p_ref text, p_title text, p_body text, p_url text)
returns void language sql security definer set search_path to 'public' as $function$
  insert into public.notification_outbox (user_id, kind, ref, title, body, url)
  values (p_user, p_kind, p_ref, left(p_title, 120), left(p_body, 240), p_url)
  on conflict (kind, ref, user_id) do nothing;
$function$;

create or replace function public.queue_test_push()
returns void language sql security definer set search_path to 'public' as $function$
  select public.enqueue_notification(auth.uid(), 'test', gen_random_uuid()::text,
    'AUDAC Rep Portal', 'Notifications are on. You''ll hear from us about new leads and your reviews.', '/home');
$function$;

-- New lead forwarded to a rep firm (Parent Account = the firm): its active reps.
create or replace function public.notify_new_lead()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  begin
    if new.rep_firm_id is null or new.crm_status_reason is distinct from 'Forwarded'
       or public.crm_lead_route(new) <> 'rep' or coalesce(new.created_on, now()) < now() - interval '14 days' then
      return new;
    end if;
    if tg_op = 'UPDATE' and public.crm_lead_route(old) = 'rep' and old.rep_firm_id is not distinct from new.rep_firm_id then
      return new;
    end if;
    perform public.enqueue_notification(p.id, 'lead', new.external_id, 'New lead from AUDAC',
      concat_ws(' · ', coalesce(new.company, new.full_name), nullif(concat_ws(', ', new.city, coalesce(new.state_code, new.state_raw)), '')),
      '/territory#leads')
    from public.profiles p where p.rep_firm_id = new.rep_firm_id and p.role = 'rep' and coalesce(p.is_active, true);
  exception when others then raise warning 'notify_new_lead: %', sqlerrm;
  end;
  return new;
end; $function$;

-- Review finalized: the firm's active reps.
create or replace function public.notify_review_finalized()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  begin
    if not coalesce(new.is_finalized, false) or (tg_op = 'UPDATE' and coalesce(old.is_finalized, false)) then return new; end if;
    perform public.enqueue_notification(p.id, 'review', new.id::text,
      'Your ' || to_char(to_date(new.reporting_month || '-01', 'YYYY-MM-DD'), 'FMMonth') || ' review is ready',
      case when coalesce(trim(new.rep_feedback), '') <> '' then 'AUDAC left you feedback. Have a look.' else 'See how your firm did this month.' end,
      '/home')
    from public.profiles p where p.rep_firm_id = new.rep_firm_id and p.role = 'rep' and coalesce(p.is_active, true);
  exception when others then raise warning 'notify_review_finalized: %', sqlerrm;
  end;
  return new;
end; $function$;

-- Questions: a new one goes to the managers; an answered one back to the rep.
create or replace function public.notify_rep_question()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_firm text;
begin
  begin
    if tg_op = 'INSERT' then
      select name into v_firm from public.rep_firms where id = new.rep_firm_id;
      perform public.enqueue_notification(p.id, 'question', new.id::text,
        'New question from ' || coalesce(new.submitted_by_name, 'a rep') || coalesce(' (' || v_firm || ')', ''),
        left(new.message, 140), '/reps#questions')
      from public.profiles p where p.role = 'manager' and coalesce(p.is_active, true);
    elsif new.status = 'answered' and old.status is distinct from 'answered' then
      perform public.enqueue_notification(new.user_id, 'answered', new.id::text || ':' || coalesce(new.answered_at, now())::text,
        'AUDAC answered your question', left(new.message, 120), '/resources#ask');
    end if;
  exception when others then raise warning 'notify_rep_question: %', sqlerrm;
  end;
  return new;
end; $function$;

create trigger crm_leads_notify after insert or update on public.crm_leads
  for each row execute function public.notify_new_lead();
create trigger monthly_reviews_notify after insert or update of is_finalized on public.monthly_reviews
  for each row execute function public.notify_review_finalized();
create trigger rep_questions_notify after insert or update of status on public.rep_questions
  for each row execute function public.notify_rep_question();

-- ---- grants ----
revoke all on function public.save_push_subscription(text, text, text, text) from public, anon;
revoke all on function public.remove_push_subscription(text) from public, anon;
revoke all on function public.push_public_key() from public, anon;
revoke all on function public.queue_test_push() from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.remove_push_subscription(text) to authenticated;
grant execute on function public.push_public_key() to authenticated;
grant execute on function public.queue_test_push() to authenticated;
revoke all on function public.push_vapid_get() from public, anon, authenticated;
revoke all on function public.push_vapid_put(text, text) from public, anon, authenticated;
revoke all on function public.enqueue_notification(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.push_vapid_get() to service_role;
grant execute on function public.push_vapid_put(text, text) to service_role;
revoke all on function public.notify_new_lead() from public, anon, authenticated;
revoke all on function public.notify_review_finalized() from public, anon, authenticated;
revoke all on function public.notify_rep_question() from public, anon, authenticated;

-- ---- every minute, only when something is waiting ----
-- Same internal key and gateway token as the nightly CRM sync job.
do $$
declare v_jwt text;
begin
  select substring(command from 'Bearer (eyJ[A-Za-z0-9._-]+)') into v_jwt from cron.job where jobname = 'crm-nightly-sync';
  perform cron.schedule('push-send', '* * * * *', format($cmd$
    select net.http_post(
      url := 'https://dhabmvpngjgrepyklius.supabase.co/functions/v1/push-send',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer %s', 'x-sync-secret', public.crm_sync_secret()),
      body := '{}'::jsonb,
      timeout_milliseconds := 15000
    ) where exists (select 1 from public.notification_outbox where sent_at is null);
  $cmd$, v_jwt));
end $$;
