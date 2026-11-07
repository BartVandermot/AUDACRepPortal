-- Rep-side tone (Bart, 2026-11-07): reps see AUDAC's written note, not a
-- monthly score. So the "review finalized" push only goes out when AUDAC
-- actually wrote a note for the firm, and it's worded as a note, not a grade.
-- Apply together with the rep-tone branch merge.

create or replace function public.notify_review_finalized()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  begin
    if not coalesce(new.is_finalized, false) or (tg_op = 'UPDATE' and coalesce(old.is_finalized, false)) then return new; end if;
    if coalesce(trim(new.rep_feedback), '') = '' then return new; end if;
    perform public.enqueue_notification(p.id, 'review', new.id::text,
      'A note from AUDAC',
      'About ' || to_char(to_date(new.reporting_month || '-01', 'YYYY-MM-DD'), 'FMMonth') || '. Open the portal to read it.',
      '/home')
    from public.profiles p where p.rep_firm_id = new.rep_firm_id and p.role = 'rep' and coalesce(p.is_active, true);
  exception when others then raise warning 'notify_review_finalized: %', sqlerrm;
  end;
  return new;
end; $function$;
