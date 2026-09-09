-- create_manual_crm_account/create_manual_crm_contact are called with no
-- login (a rep adding a dealer that isn't in CRM yet), and take rep_firm_id
-- as a plain parameter with no real way to verify the caller actually
-- represents that firm -- there's no session to check it against. That's an
-- unavoidable consequence of keeping the form anonymous, not something a
-- database-side fix can close outright. What it CAN do is stop a script or
-- bot from flooding the table, mirroring the exact same "good enough"
-- velocity-cap pattern already used for activity_entries (see migration
-- 0014) -- a blunt per-firm rate limit that no real rep would ever hit, but
-- that bounds the damage of automated abuse. Genuine one-off misattribution
-- isn't something this (or anything, short of requiring login) can prevent,
-- but manually-added rows already land in a reviewable bucket (see
-- crm.html's "Manually Added -- Needs CRM Import" filter), so the residual
-- risk here is bounded spam, not silent data corruption.
create or replace function public.enforce_manual_crm_account_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recent_count integer;
begin
  if new.source = 'manual' and new.rep_firm_id is not null then
    select count(*) into v_recent_count
    from public.crm_accounts
    where rep_firm_id = new.rep_firm_id
      and source = 'manual'
      and updated_at > now() - interval '5 minutes';
    if v_recent_count >= 20 then
      raise exception 'Too many manually-added accounts for this firm in a short period. Please wait a few minutes and try again.';
    end if;
  end if;
  return new;
end;
$$;

create trigger crm_accounts_manual_rate_limit_trigger
  before insert on public.crm_accounts
  for each row execute function public.enforce_manual_crm_account_rate_limit();

revoke all on function public.enforce_manual_crm_account_rate_limit() from public, anon, authenticated;

create or replace function public.enforce_manual_crm_contact_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recent_count integer;
begin
  if new.source = 'manual' and new.rep_firm_id is not null then
    select count(*) into v_recent_count
    from public.crm_contacts
    where rep_firm_id = new.rep_firm_id
      and source = 'manual'
      and updated_at > now() - interval '5 minutes';
    if v_recent_count >= 20 then
      raise exception 'Too many manually-added contacts for this firm in a short period. Please wait a few minutes and try again.';
    end if;
  end if;
  return new;
end;
$$;

create trigger crm_contacts_manual_rate_limit_trigger
  before insert on public.crm_contacts
  for each row execute function public.enforce_manual_crm_contact_rate_limit();

revoke all on function public.enforce_manual_crm_contact_rate_limit() from public, anon, authenticated;
