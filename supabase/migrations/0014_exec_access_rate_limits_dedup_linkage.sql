-- 1. Executive read access to crm_accounts, needed for a dormant-accounts
-- summary on executive.html (previously manager-only; still no write access).
create policy "crm_accounts_select_executive" on public.crm_accounts
  for select using (public.current_role_name() = 'executive');

-- ---------------------------------------------------------------------------
-- 2. Rate limiting. Real per-IP throttling isn't possible from a plain
-- Postgres trigger -- Postgres never sees the client's IP, only PostgREST/the
-- API gateway does, so this can't distinguish "one person submitting a lot"
-- from "many people submitting a little". What IS achievable here: a blunt,
-- generous velocity cap that stops a runaway flood (bot, broken retry loop,
-- bulk-script misuse of the public endpoint) without interfering with real
-- usage. True per-client throttling would need an Edge Function in front of
-- the insert (it can read request headers for the real IP); this is the
-- database-only version of "good enough" protection.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_activity_entries_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recent_count integer;
begin
  select count(*) into v_recent_count
  from public.activity_entries
  where rep_firm_id = new.rep_firm_id
    and submitted_at > now() - interval '5 minutes';
  if v_recent_count >= 100 then
    raise exception 'Too many activity submissions for this firm in a short period. Please wait a few minutes and try again.';
  end if;
  return new;
end;
$$;

create trigger activity_entries_rate_limit_trigger
  before insert on public.activity_entries
  for each row execute function public.enforce_activity_entries_rate_limit();

revoke all on function public.enforce_activity_entries_rate_limit() from public, anon, authenticated;

-- Attachment count is already capped at 3 client-side in form.html, but that's
-- trivially bypassed by calling the API directly -- this is the real guardrail.
create or replace function public.enforce_max_attachments_per_entry()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  select count(*) into v_count from public.activity_attachments where activity_entry_id = new.activity_entry_id;
  if v_count >= 3 then
    raise exception 'Maximum 3 attachments per activity entry.';
  end if;
  return new;
end;
$$;

create trigger activity_attachments_max_per_entry_trigger
  before insert on public.activity_attachments
  for each row execute function public.enforce_max_attachments_per_entry();

revoke all on function public.enforce_max_attachments_per_entry() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Duplicate-entry detection. anon can't SELECT activity_entries at all (by
-- design), so a client-side "does this already exist" check needs a narrow
-- security-definer RPC -- same pattern as search_crm_accounts etc. This is a
-- soft check (the form warns and lets the rep submit anyway), not a hard
-- constraint, since two genuinely separate visits can share every one of
-- these fields.
-- ---------------------------------------------------------------------------
create or replace function public.check_duplicate_activity(p_rep_firm_id uuid, p_account_name text, p_entry_date date, p_activity_type text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.activity_entries
    where rep_firm_id = p_rep_firm_id
      and lower(trim(account_name)) = lower(trim(coalesce(p_account_name, '')))
      and entry_date = p_entry_date
      and activity_type = p_activity_type
  );
$$;

revoke all on function public.check_duplicate_activity(uuid, text, date, text) from public;
grant execute on function public.check_duplicate_activity(uuid, text, date, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Activity <-> pipeline linkage. Pipeline entries are manager-imported via
-- CSV, not rep-submitted, so this is a manual "which activity led to this"
-- link a manager sets, not something a rep fills in. Nullable, one-directional
-- (an activity can have many pipeline entries pointing at it).
-- ---------------------------------------------------------------------------
alter table public.pipeline_entries add column related_activity_entry_id uuid references public.activity_entries(id);
