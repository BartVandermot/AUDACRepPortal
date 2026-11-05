-- Adoption insight.
-- get_rep_usage(): for the manager -- every rep login with last sign-in and
--   activity numbers, to see which firms/reps drop off.
-- get_my_team(): for a firm admin (is_rep_admin) -- the same for the reps of
--   their own firm only, so the firm can push its own people.
-- last_sign_in_at lives in auth.users, which the API can't read: hence
-- security definer, with the role check inside.

create or replace function public.get_rep_usage()
returns table(rep_id uuid, email text, full_name text, rep_firm_id uuid, is_active boolean, is_rep_admin boolean,
              last_sign_in_at timestamptz, last_activity_date date, acts_this_month bigint, acts_30d bigint, acts_total bigint)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.id, p.email, p.full_name, p.rep_firm_id, p.is_active, p.is_rep_admin,
         u.last_sign_in_at,
         (select max(e.entry_date) from public.activity_entries e where e.created_by = p.id),
         (select count(*) from public.activity_entries e where e.created_by = p.id and e.reporting_month = to_char(current_date, 'YYYY-MM')),
         (select count(*) from public.activity_entries e where e.created_by = p.id and e.submitted_at >= now() - interval '30 days'),
         (select count(*) from public.activity_entries e where e.created_by = p.id)
    from public.profiles p
    join auth.users u on u.id = p.id
   where p.role = 'rep'
     and public.current_role_name() = any (array['manager', 'executive'])
   order by p.rep_firm_id, p.full_name nulls last, p.email;
$function$;

create or replace function public.get_my_team()
returns table(rep_id uuid, full_name text, email text, is_rep_admin boolean,
              last_sign_in_at timestamptz, last_activity_date date, acts_this_month bigint, acts_prev_month bigint, acts_30d bigint)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with me as (
    select p.rep_firm_id from public.profiles p
     where p.id = auth.uid() and p.role = 'rep' and p.is_active and p.is_rep_admin and p.rep_firm_id is not null
  )
  select p.id, p.full_name, p.email, p.is_rep_admin,
         u.last_sign_in_at,
         (select max(e.entry_date) from public.activity_entries e where e.created_by = p.id),
         (select count(*) from public.activity_entries e where e.created_by = p.id and e.reporting_month = to_char(current_date, 'YYYY-MM')),
         (select count(*) from public.activity_entries e where e.created_by = p.id and e.reporting_month = to_char(current_date - interval '1 month', 'YYYY-MM')),
         (select count(*) from public.activity_entries e where e.created_by = p.id and e.submitted_at >= now() - interval '30 days')
    from public.profiles p
    join auth.users u on u.id = p.id
    join me on me.rep_firm_id = p.rep_firm_id
   where p.role = 'rep' and p.is_active
   order by 7 desc, p.full_name nulls last;
$function$;

revoke all on function public.get_rep_usage() from public, anon;
revoke all on function public.get_my_team() from public, anon;
grant execute on function public.get_rep_usage() to authenticated;
grant execute on function public.get_my_team() to authenticated;
