-- One friendly reminder per lead (Bart, 2026-11-07): a lead handed to the
-- firm (route rep / trade_show, status Forwarded) that still has no "What came
-- of it?" 10 days later gets one push to the firm's active reps. Never again
-- for that lead; several leads due on the same day go in one push. Leads older
-- than the 60-day follow-up window (AudacShell.LEAD_FOLLOW_UP_DAYS) are left
-- alone. Runs daily at 14:00 UTC (morning in the US). Applied via execute_sql.

create table if not exists public.lead_reminders (
  lead_external_id text not null,
  user_id uuid not null references auth.users(id),
  reminded_at timestamptz not null default now(),
  primary key (lead_external_id, user_id)
);
alter table public.lead_reminders enable row level security;
create policy lead_reminders_manager on public.lead_reminders for select to authenticated using (public.current_role_name() = 'manager');
revoke all on public.lead_reminders from anon;
grant select on public.lead_reminders to authenticated;

create or replace function public.queue_lead_reminders()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_pushes integer := 0; v_leads integer := 0;
begin
  with due as (
    select p.id as user_id, l.external_id, coalesce(l.company, l.full_name, 'A lead') as who
      from public.crm_leads l
      join public.profiles p on p.rep_firm_id = l.rep_firm_id and p.role = 'rep' and coalesce(p.is_active, true)
     where l.rep_firm_id is not null
       and l.crm_status_reason = 'Forwarded'
       and public.crm_lead_route(l) in ('rep', 'trade_show')
       and l.created_on < now() - interval '10 days'
       and l.created_on > now() - interval '60 days'
       and not exists (select 1 from public.lead_followups f where f.lead_external_id = l.external_id)
       and not exists (select 1 from public.lead_reminders r where r.lead_external_id = l.external_id and r.user_id = p.id)
  ), pushes as (
    select public.enqueue_notification(d.user_id, 'lead_reminder', d.user_id::text || ':' || current_date::text,
             case when count(*) = 1 then 'How did this lead go?' else count(*) || ' leads: how did they go?' end,
             case when count(*) = 1 then min(d.who) || ': a quick word on what came of it helps AUDAC send you better leads.'
                  else string_agg(d.who, ', ' order by d.who) || '. Two clicks each on My territory.' end,
             '/territory#leads')
      from due d group by d.user_id
  ), marked as (
    insert into public.lead_reminders (lead_external_id, user_id)
    select external_id, user_id from due
    on conflict do nothing
    returning 1
  )
  select (select count(*) from pushes), (select count(*) from marked) into v_pushes, v_leads;
  return v_leads;
end;
$function$;
revoke all on function public.queue_lead_reminders() from public, anon, authenticated;

select cron.schedule('lead-reminders', '0 14 * * *', $cmd$ select public.queue_lead_reminders(); $cmd$);
