-- ---------------------------------------------------------------------------
-- 1. No future-dated activity. entry_date records something that already
-- happened, so a date after today is always a data-entry mistake (wrong year
-- picked, etc). Enforced at the DB layer, not just client-side, since
-- activity_entries is publicly insertable by anon.
-- ---------------------------------------------------------------------------
alter table public.activity_entries
  add constraint activity_entries_no_future_date check (entry_date <= current_date);

-- ---------------------------------------------------------------------------
-- 2. Monthly review finalization. A manager can "finalize" a firm+month once
-- the review conversation has happened, freezing that period's activity_entries
-- against further insert/update/delete -- otherwise the record a review was
-- based on can silently drift afterward. Un-finalizing is an explicit,
-- separate action (still manager-only, same RLS as the rest of monthly_reviews)
-- so corrections stay possible but never accidental/silent.
-- ---------------------------------------------------------------------------
alter table public.monthly_reviews
  add column is_finalized boolean not null default false,
  add column finalized_at timestamptz,
  add column finalized_by uuid references auth.users(id);

create or replace function public.enforce_activity_entries_period_not_finalized()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_firm uuid;
  v_month text;
begin
  if tg_op = 'DELETE' then
    v_firm := old.rep_firm_id;
    v_month := old.reporting_month;
  else
    v_firm := new.rep_firm_id;
    v_month := new.reporting_month;
  end if;

  if exists (
    select 1 from public.monthly_reviews
    where rep_firm_id = v_firm and reporting_month = v_month and is_finalized
  ) then
    raise exception 'This reporting period has been finalized and can no longer be changed. Ask a manager to un-finalize it first.';
  end if;

  -- An update can't be used to move an entry OUT of a finalized period either.
  if tg_op = 'UPDATE' and exists (
    select 1 from public.monthly_reviews
    where rep_firm_id = old.rep_firm_id and reporting_month = old.reporting_month and is_finalized
  ) then
    raise exception 'This reporting period has been finalized and can no longer be changed. Ask a manager to un-finalize it first.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger activity_entries_period_lock_trigger
  before insert or update or delete on public.activity_entries
  for each row execute function public.enforce_activity_entries_period_not_finalized();

revoke all on function public.enforce_activity_entries_period_not_finalized() from public, anon, authenticated;
