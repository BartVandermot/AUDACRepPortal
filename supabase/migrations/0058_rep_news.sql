-- News for reps on Home (Bart, 2026-11-07): a product launch, a webinar, a
-- price change, a trade show. One line plus an optional link, shown between
-- two dates. Managers write it (Data Admin -> News for reps); reps only see
-- what's current.

create table public.rep_news (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 1 and 120),
  body text check (body is null or length(body) <= 500),
  link_url text check (link_url is null or link_url ~ '^https://'),
  starts_on date not null default current_date,
  ends_on date not null,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on)
);
create index rep_news_dates_idx on public.rep_news (ends_on, starts_on);

alter table public.rep_news enable row level security;

create policy rep_news_select on public.rep_news for select to authenticated
  using (public.current_role_name() in ('manager', 'executive')
         or (public.current_role_name() = 'rep' and current_date between starts_on and ends_on));
create policy rep_news_insert_manager on public.rep_news for insert to authenticated
  with check (public.current_role_name() = 'manager');
create policy rep_news_update_manager on public.rep_news for update to authenticated
  using (public.current_role_name() = 'manager') with check (public.current_role_name() = 'manager');
create policy rep_news_delete_manager on public.rep_news for delete to authenticated
  using (public.current_role_name() = 'manager');

revoke all on public.rep_news from anon;
grant select, insert, update, delete on public.rep_news to authenticated;
