-- Opportunities eventually close (Won or Lost), and that outcome is real
-- information a manager/executive should see -- restricting the sync to
-- Open only (as the previous migration did) would silently lose every deal
-- the moment it closes. pipeline_entries now needs to distinguish status,
-- since it can hold closed rows going forward. Null status on existing rows
-- means "assume Open" -- every pre-existing row (CSV imports and the
-- Open-only sync) represents open pipeline by definition, so this doesn't
-- reclassify anything retroactively.
alter table public.pipeline_entries
  add column status text check (status in ('Open', 'Won', 'Lost')),
  add column actual_value_usd numeric(14, 2),
  add column actual_close_date date;

comment on column public.pipeline_entries.status is 'Open/Won/Lost as of the last sync/import. Null on older rows means Open.';
comment on column public.pipeline_entries.actual_value_usd is 'Realized deal value once Won -- value_usd stays the estimate, so a closed deal''s historical Open-period snapshots aren''t rewritten.';
comment on column public.pipeline_entries.actual_close_date is 'When the deal actually closed (Won or Lost) -- distinct from expected_close_date, which is the Open-period projection.';

-- get_rag_scorecard's "Pipeline Entries"/"Pipeline Value" columns represent
-- OPEN pipeline -- without this filter, a Won or Lost deal synced into the
-- same table would inflate that month's pipeline count/value with a deal
-- that isn't pipeline anymore, corrupting the RAG score itself. This is the
-- one change genuinely required by allowing closed rows into the table at
-- all, not an optional improvement.
create or replace function public.get_rag_scorecard(p_month text)
returns table (
  rep_firm_id uuid,
  firm_name text,
  territory text,
  activity_count bigint,
  demo_gear_count bigint,
  pipeline_count bigint,
  pipeline_value_usd numeric,
  education_count bigint,
  sellout_revenue numeric,
  prior_sellout_revenue numeric,
  rag_status text
)
language sql
stable
security definer
set search_path = public
as $$
  with prior as (
    select to_char((to_date(p_month || '-01', 'YYYY-MM-DD') - interval '1 month'), 'YYYY-MM') as month
  ),
  acts as (
    select rep_firm_id, count(*) as activity_count,
           count(*) filter (where demo_gear_used) as demo_gear_count
    from public.activity_entries
    where reporting_month = p_month
    group by rep_firm_id
  ),
  pipe as (
    select rep_firm_id, count(*) as pipeline_count, sum(value_usd) as pipeline_value_usd
    from public.pipeline_entries
    where reporting_month = p_month and (status is null or status = 'Open')
    group by rep_firm_id
  ),
  edu as (
    select rep_firm_id, count(*) as education_count
    from public.education_records
    where reporting_month = p_month
    group by rep_firm_id
  ),
  sell as (
    select rep_firm_id, sum(revenue_usd) as sellout_revenue
    from public.sellout_records
    where reporting_month = p_month
    group by rep_firm_id
  ),
  sell_prior as (
    select s.rep_firm_id, sum(s.revenue_usd) as prior_sellout_revenue
    from public.sellout_records s, prior
    where s.reporting_month = prior.month
    group by s.rep_firm_id
  )
  select
    f.id as rep_firm_id,
    f.name as firm_name,
    f.territory,
    coalesce(a.activity_count, 0) as activity_count,
    coalesce(a.demo_gear_count, 0) as demo_gear_count,
    coalesce(p.pipeline_count, 0) as pipeline_count,
    coalesce(p.pipeline_value_usd, 0) as pipeline_value_usd,
    coalesce(e.education_count, 0) as education_count,
    coalesce(s.sellout_revenue, 0) as sellout_revenue,
    coalesce(sp.prior_sellout_revenue, 0) as prior_sellout_revenue,
    case
      when coalesce(a.activity_count, 0) = 0 then 'Red'
      when coalesce(a.activity_count, 0) < 4 then 'Red'
      when coalesce(a.activity_count, 0) between 4 and 7 then 'Amber'
      when coalesce(p.pipeline_count, 0) = 0 then 'Amber'
      else 'Green'
    end as rag_status
  from public.rep_firms f
  left join acts a on a.rep_firm_id = f.id
  left join pipe p on p.rep_firm_id = f.id
  left join edu e on e.rep_firm_id = f.id
  left join sell s on s.rep_firm_id = f.id
  left join sell_prior sp on sp.rep_firm_id = f.id
  where f.status = 'active'
    and public.current_role_name() in ('manager', 'executive')
  order by f.name;
$$;
