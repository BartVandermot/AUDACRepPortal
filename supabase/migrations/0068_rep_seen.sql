-- What a rep has already seen on Home (Bart, 2026-11-09): "New for you" only
-- shows what's actually new. Keys: 'q:<question id>' (answered question,
-- marked when the rep opens Resources -> Ask AUDAC), 'note:<YYYY-MM>' (AUDAC's
-- review note, "Got it"), 'news:<news id>' ("Got it" or opening the link).
-- Per user, so phone and computer agree. Applied via execute_sql.

create table if not exists public.rep_seen (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  item_key text not null check (length(item_key) between 3 and 80),
  seen_at timestamptz not null default now(),
  primary key (user_id, item_key)
);
alter table public.rep_seen enable row level security;
create policy rep_seen_own_select on public.rep_seen for select to authenticated using (user_id = auth.uid());
create policy rep_seen_own_insert on public.rep_seen for insert to authenticated with check (user_id = auth.uid());
revoke all on public.rep_seen from anon;
grant select on public.rep_seen to authenticated;
-- The insert policy above is unused (writes go through mark_seen); dropping it
-- was declined by the MCP, and without the insert grant it does nothing.

create or replace function public.mark_seen(p_keys text[])
returns void language sql security definer set search_path to 'public' as $function$
  insert into public.rep_seen (user_id, item_key)
  select auth.uid(), k from unnest(p_keys) k
   where auth.uid() is not null and length(k) between 3 and 80
  on conflict do nothing;
$function$;
revoke all on function public.mark_seen(text[]) from public, anon;
grant execute on function public.mark_seen(text[]) to authenticated;
