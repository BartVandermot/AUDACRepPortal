-- Resources page for reps (2026-11-05):
--   * rep_questions: "Ask AUDAC". Kept in the portal (manager work list) and
--     also e-mailed from the rep's own mail app (technical -> AVL, Bart in CC).
--   * crossref_lookups: what reps search and open in the competitor
--     cross-reference tool -- input for the structural competitor-matching
--     project. Only product names, no customer data.
-- Who/which firm is filled in server-side from the caller's profile, so it
-- can't be spoofed from the browser.

create table if not exists public.rep_questions (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid not null default auth.uid() references auth.users(id),
  rep_firm_id uuid references public.rep_firms(id),
  submitted_by_name text,
  submitted_by_email text,
  topic text not null check (topic in ('technical', 'commercial', 'portal', 'other')),
  message text not null check (char_length(message) between 1 and 4000),
  sent_to text,
  status text not null default 'open' check (status in ('open', 'answered')),
  answered_at timestamptz,
  answered_by uuid references auth.users(id)
);
alter table public.rep_questions enable row level security;
create policy rep_questions_insert on public.rep_questions
  for insert with check (user_id = (select auth.uid()));
create policy rep_questions_select on public.rep_questions
  for select using (user_id = (select auth.uid()) or public.current_role_name() = any (array['manager', 'executive']));
create policy rep_questions_answer on public.rep_questions
  for update using (public.current_role_name() = 'manager') with check (public.current_role_name() = 'manager');
grant select, insert on public.rep_questions to authenticated;
grant update (status, answered_at, answered_by) on public.rep_questions to authenticated;
create index if not exists rep_questions_open_idx on public.rep_questions(created_at) where status = 'open';

create table if not exists public.crossref_lookups (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid not null default auth.uid() references auth.users(id),
  rep_firm_id uuid references public.rep_firms(id),
  kind text not null check (kind in ('search', 'open')),
  query text check (char_length(query) <= 100),
  brand text,
  model text,
  audac text
);
alter table public.crossref_lookups enable row level security;
create policy crossref_lookups_insert on public.crossref_lookups
  for insert with check (user_id = (select auth.uid()));
create policy crossref_lookups_select on public.crossref_lookups
  for select using (public.current_role_name() = any (array['manager', 'executive']));
grant select, insert on public.crossref_lookups to authenticated;
create index if not exists crossref_lookups_created_idx on public.crossref_lookups(created_at desc);

-- Fill in the submitter from the caller's profile (never trusted from the client).
create or replace function public.stamp_submitter()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare p record;
begin
  select rep_firm_id, full_name, email into p from public.profiles where id = auth.uid();
  new.user_id := auth.uid();
  new.rep_firm_id := p.rep_firm_id;
  if tg_table_name = 'rep_questions' then
    new.submitted_by_name := coalesce(p.full_name, p.email);
    new.submitted_by_email := p.email;
    new.status := 'open';
    new.answered_at := null;
    new.answered_by := null;
  end if;
  return new;
end;
$function$;
revoke all on function public.stamp_submitter() from public, anon, authenticated;

create trigger rep_questions_stamp before insert on public.rep_questions
  for each row execute function public.stamp_submitter();
create trigger crossref_lookups_stamp before insert on public.crossref_lookups
  for each row execute function public.stamp_submitter();
