-- Individual rep identity: every rep who signs in (same passwordless magic link
-- as before) now gets a profiles row (role='rep'), auto-created by a trigger on
-- auth.users so no manager setup is needed per rep. rep_firm_id starts null and
-- gets self-claimed once via claim_rep_firm() below -- the firm context the rep
-- was on when they signed in, not something they can freely reassign afterward.
alter table public.profiles add column is_rep_admin boolean not null default false;

-- Denormalized onto activity_entries so "who submitted this" can be shown without
-- a join against auth.users (not directly queryable from the client) -- same
-- pattern as activity_entries_audit.changed_by_email.
alter table public.activity_entries add column created_by_email text;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, role)
  values (new.id, new.email, 'rep')
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- A rep can't set their own rep_firm_id via a plain UPDATE (profiles write is
-- manager-only per existing RLS) -- this is the one narrow, validated exception:
-- claim exactly once, only onto an active firm, never overwriting an existing
-- claim. Mirrors the create_manual_crm_account()-style security-definer pattern
-- used elsewhere in this app.
create or replace function public.claim_rep_firm(p_firm_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Must be signed in';
  end if;
  if not exists (select 1 from public.rep_firms where id = p_firm_id and status = 'active') then
    raise exception 'Invalid rep firm';
  end if;
  update public.profiles set rep_firm_id = p_firm_id where id = auth.uid() and rep_firm_id is null;
end;
$$;

revoke all on function public.claim_rep_firm(uuid) from public, anon;
grant execute on function public.claim_rep_firm(uuid) to authenticated;

-- Firm admin access: an admin rep can see/edit/delete ANY activity_entries row
-- for their own firm (matched by rep_firm_id, not by tracking who created it) --
-- covers "fill in for a colleague" without needing to model colleague identities.
-- Additive alongside the existing created_by = auth.uid() ("own") policies from
-- migration 0011; RLS ORs multiple permissive policies together.
create policy "activity_entries_select_firm_admin" on public.activity_entries
  for select using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.is_rep_admin and p.rep_firm_id = activity_entries.rep_firm_id
    )
  );
create policy "activity_entries_update_firm_admin" on public.activity_entries
  for update using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.is_rep_admin and p.rep_firm_id = activity_entries.rep_firm_id
    )
  );
create policy "activity_entries_delete_firm_admin" on public.activity_entries
  for delete using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.is_rep_admin and p.rep_firm_id = activity_entries.rep_firm_id
    )
  );
