-- Melissa's feedback: an activity entry identifies the rep (email) and the
-- rep firm, but not which part of the firm's territory that individual rep
-- actually covers -- there was nowhere to record that at all. Tracked purely
-- on our side (free text, like rep_firms.territory already is) rather than
-- in Dataverse.
alter table public.profiles add column if not exists territory_note text;

-- Individual reps already exist as real Dataverse Contacts under their own
-- firm's Account record (parent_account_external_id = that firm's
-- crm_account_external_id) -- this links a rep's portal profile to that
-- existing CRM identity instead of the portal only ever knowing them by
-- whatever email they happened to sign in with.
alter table public.profiles add column if not exists crm_contact_external_id text references public.crm_contacts(external_id);

-- Auto-matches by email whenever a rep's firm is set/changed (self-claimed on
-- first sign-in, or corrected on the Reps page) -- re-running on every firm
-- change keeps this from going stale if a rep is ever reassigned. Clears to
-- null on no match rather than leaving a previous (now wrong-firm) link
-- behind; a manager can still hand-pick the right contact afterward on the
-- Reps page, which updates crm_contact_external_id alone and so isn't
-- touched by this trigger again unless the firm changes once more.
create or replace function public.auto_link_rep_crm_contact()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_crm_account_external_id text;
begin
  if new.rep_firm_id is null or new.email is null then
    new.crm_contact_external_id := null;
    return new;
  end if;

  select crm_account_external_id into v_crm_account_external_id
    from public.rep_firms where id = new.rep_firm_id;

  if v_crm_account_external_id is null then
    new.crm_contact_external_id := null;
    return new;
  end if;

  select external_id into new.crm_contact_external_id
    from public.crm_contacts
    where parent_account_external_id = v_crm_account_external_id
      and email_key = lower(trim(new.email))
    limit 1;

  return new;
end;
$$;

drop trigger if exists profiles_auto_link_crm_contact on public.profiles;
create trigger profiles_auto_link_crm_contact
  before insert or update of rep_firm_id on public.profiles
  for each row execute function public.auto_link_rep_crm_contact();

-- Backfill existing reps now, rather than waiting for their next firm change.
update public.profiles p
set crm_contact_external_id = (
  select cc.external_id from public.crm_contacts cc
  join public.rep_firms rf on rf.crm_account_external_id = cc.parent_account_external_id
  where rf.id = p.rep_firm_id and cc.email_key = lower(trim(p.email))
  limit 1
)
where p.role = 'rep' and p.rep_firm_id is not null;
