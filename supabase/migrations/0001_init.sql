-- AUDAC Rep Portal — initial schema
-- Tables, RLS policies, helper functions, RAG scorecard RPC

create extension if not exists pgcrypto;

-- ============================================================
-- REP FIRMS
-- ============================================================
create table public.rep_firms (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  territory text not null,
  states text[] not null default '{}',
  contact_name text,
  contact_email text,
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now()
);

-- ============================================================
-- PROFILES (role assignment for authenticated users)
-- ============================================================
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role text not null check (role in ('rep', 'manager', 'executive')),
  rep_firm_id uuid references public.rep_firms(id),
  created_at timestamptz not null default now()
);

-- ============================================================
-- ACTIVITY ENTRIES (submitted via public rep form)
-- ============================================================
create table public.activity_entries (
  id uuid primary key default gen_random_uuid(),
  rep_firm_id uuid not null references public.rep_firms(id),
  reporting_month text not null check (reporting_month ~ '^\d{4}-\d{2}$'),
  submitted_at timestamptz not null default now(),
  entry_date date not null,
  account_name text not null,
  contact_type text not null check (contact_type in ('Dealer', 'Consultant', 'End User')),
  activity_type text not null check (activity_type in (
    'Brand Introduction', 'Demo', 'Follow Up', 'Lunch & Learn',
    'Online Demo', 'Dealer Training', 'Other'
  )),
  demo_gear_used boolean not null default false,
  topic_opportunity text,
  solution_feedback text,
  competitive_feedback text,
  additional_comments text
);

create index idx_activity_entries_firm_month on public.activity_entries (rep_firm_id, reporting_month);

-- ============================================================
-- EDUCATION RECORDS (CSV upload — education.audac.eu export)
-- ============================================================
create table public.education_records (
  id uuid primary key default gen_random_uuid(),
  rep_firm_id uuid not null references public.rep_firms(id),
  reporting_month text not null check (reporting_month ~ '^\d{4}-\d{2}$'),
  person_name text not null,
  course_name text not null,
  completion_date date,
  certificate_url text,
  uploaded_at timestamptz not null default now()
);

create index idx_education_records_firm_month on public.education_records (rep_firm_id, reporting_month);

-- ============================================================
-- PIPELINE ENTRIES (CSV upload — D365 export)
-- ============================================================
create table public.pipeline_entries (
  id uuid primary key default gen_random_uuid(),
  rep_firm_id uuid not null references public.rep_firms(id),
  reporting_month text not null check (reporting_month ~ '^\d{4}-\d{2}$'),
  account_name text not null,
  project_name text,
  stage text,
  value_usd numeric(14, 2),
  created_date date,
  expected_close_date date,
  crm_id text,
  uploaded_at timestamptz not null default now()
);

create index idx_pipeline_entries_firm_month on public.pipeline_entries (rep_firm_id, reporting_month);

-- ============================================================
-- SELLOUT RECORDS (CSV upload — AVL sell-out export)
-- ============================================================
create table public.sellout_records (
  id uuid primary key default gen_random_uuid(),
  rep_firm_id uuid not null references public.rep_firms(id),
  reporting_month text not null check (reporting_month ~ '^\d{4}-\d{2}$'),
  dealer_name text,
  product_sku text,
  quantity numeric(12, 2),
  revenue_usd numeric(14, 2),
  uploaded_at timestamptz not null default now()
);

create index idx_sellout_records_firm_month on public.sellout_records (rep_firm_id, reporting_month);

-- ============================================================
-- MONTHLY REVIEWS (manager RAG override + agenda notes)
-- ============================================================
create table public.monthly_reviews (
  id uuid primary key default gen_random_uuid(),
  rep_firm_id uuid not null references public.rep_firms(id),
  reporting_month text not null check (reporting_month ~ '^\d{4}-\d{2}$'),
  rag_status text check (rag_status in ('Red', 'Amber', 'Green')),
  notes text,
  agenda_generated_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (rep_firm_id, reporting_month)
);

-- ============================================================
-- CSV COLUMN MAPPINGS (saved per source for repeat uploads)
-- ============================================================
create table public.csv_column_mappings (
  id uuid primary key default gen_random_uuid(),
  source text not null unique check (source in ('crm_accounts', 'education', 'pipeline', 'sellout')),
  mapping jsonb not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

-- ============================================================
-- HELPER: current user's role
-- ============================================================
create or replace function public.current_role_name()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ============================================================
-- RLS
-- ============================================================
alter table public.rep_firms enable row level security;
alter table public.profiles enable row level security;
alter table public.activity_entries enable row level security;
alter table public.education_records enable row level security;
alter table public.pipeline_entries enable row level security;
alter table public.sellout_records enable row level security;
alter table public.monthly_reviews enable row level security;
alter table public.csv_column_mappings enable row level security;

-- rep_firms: readable by anyone (public form needs the firm list), writable by managers only
create policy "rep_firms_select_all" on public.rep_firms
  for select using (true);
create policy "rep_firms_write_manager" on public.rep_firms
  for all using (public.current_role_name() = 'manager')
  with check (public.current_role_name() = 'manager');

-- profiles: users see their own row; managers/executives see all
create policy "profiles_select_own_or_staff" on public.profiles
  for select using (id = auth.uid() or public.current_role_name() in ('manager', 'executive'));
create policy "profiles_write_manager" on public.profiles
  for all using (public.current_role_name() = 'manager')
  with check (public.current_role_name() = 'manager');

-- activity_entries: anyone (incl. anon) can insert via the public rep form;
-- only manager/executive can read; only manager can update/delete
create policy "activity_entries_insert_public" on public.activity_entries
  for insert with check (true);
create policy "activity_entries_select_staff" on public.activity_entries
  for select using (public.current_role_name() in ('manager', 'executive'));
create policy "activity_entries_modify_manager" on public.activity_entries
  for update using (public.current_role_name() = 'manager');
create policy "activity_entries_delete_manager" on public.activity_entries
  for delete using (public.current_role_name() = 'manager');

-- education/pipeline/sellout: manager writes (CSV upload), manager+executive read
create policy "education_records_select_staff" on public.education_records
  for select using (public.current_role_name() in ('manager', 'executive'));
create policy "education_records_write_manager" on public.education_records
  for insert with check (public.current_role_name() = 'manager');
create policy "education_records_update_manager" on public.education_records
  for update using (public.current_role_name() = 'manager');
create policy "education_records_delete_manager" on public.education_records
  for delete using (public.current_role_name() = 'manager');

create policy "pipeline_entries_select_staff" on public.pipeline_entries
  for select using (public.current_role_name() in ('manager', 'executive'));
create policy "pipeline_entries_write_manager" on public.pipeline_entries
  for insert with check (public.current_role_name() = 'manager');
create policy "pipeline_entries_update_manager" on public.pipeline_entries
  for update using (public.current_role_name() = 'manager');
create policy "pipeline_entries_delete_manager" on public.pipeline_entries
  for delete using (public.current_role_name() = 'manager');

create policy "sellout_records_select_staff" on public.sellout_records
  for select using (public.current_role_name() in ('manager', 'executive'));
create policy "sellout_records_write_manager" on public.sellout_records
  for insert with check (public.current_role_name() = 'manager');
create policy "sellout_records_update_manager" on public.sellout_records
  for update using (public.current_role_name() = 'manager');
create policy "sellout_records_delete_manager" on public.sellout_records
  for delete using (public.current_role_name() = 'manager');

-- monthly_reviews: manager writes, manager+executive read
create policy "monthly_reviews_select_staff" on public.monthly_reviews
  for select using (public.current_role_name() in ('manager', 'executive'));
create policy "monthly_reviews_write_manager" on public.monthly_reviews
  for insert with check (public.current_role_name() = 'manager');
create policy "monthly_reviews_update_manager" on public.monthly_reviews
  for update using (public.current_role_name() = 'manager');
create policy "monthly_reviews_delete_manager" on public.monthly_reviews
  for delete using (public.current_role_name() = 'manager');

-- csv_column_mappings: manager only
create policy "csv_column_mappings_select_manager" on public.csv_column_mappings
  for select using (public.current_role_name() = 'manager');
create policy "csv_column_mappings_write_manager" on public.csv_column_mappings
  for all using (public.current_role_name() = 'manager')
  with check (public.current_role_name() = 'manager');

-- ============================================================
-- RAG SCORECARD RPC
-- Green: submitted + >=8 activities + >=1 pipeline entry
-- Amber: submitted + (4-7 activities OR zero pipeline entries)
-- Red:   not submitted (0 activities) OR <4 activities
-- ============================================================
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
    where reporting_month = p_month
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

revoke all on function public.current_role_name() from public, anon;
grant execute on function public.current_role_name() to authenticated;
revoke all on function public.get_rag_scorecard(text) from public, anon;
grant execute on function public.get_rag_scorecard(text) to authenticated;
