-- 1) Ask AUDAC: sales questions reach Bart directly via Teams, WhatsApp or mail.
alter table public.rep_questions add column if not exists channel text
  check (channel in ('email', 'teams', 'whatsapp'));

-- 2) Competitor cross-reference data in the database instead of inside a public
--    HTML file. Readable only by signed-in, active reps/managers/executives,
--    through get_crossref(). Every upload is kept as a version; one is current.
create table if not exists public.crossref_versions (
  version text primary key,
  uploaded_at timestamptz not null default now(),
  uploaded_by uuid default auth.uid() references auth.users(id),
  source_name text,
  pair_count integer not null default 0,
  is_current boolean not null default false
);
create table if not exists public.crossref_pairings (
  id uuid primary key default gen_random_uuid(),
  version text not null references public.crossref_versions(version) on delete cascade,
  position integer not null,
  data jsonb not null,
  unique (version, position)
);
alter table public.crossref_versions enable row level security;
alter table public.crossref_pairings enable row level security;
create policy crossref_versions_manager_read on public.crossref_versions
  for select using (public.current_role_name() = 'manager');
grant select on public.crossref_versions to authenticated;
-- No direct read on crossref_pairings for anyone: only via get_crossref().

create or replace function public.get_crossref()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_out jsonb;
begin
  if not exists (select 1 from public.profiles p
                  where p.id = auth.uid() and coalesce(p.is_active, true)
                    and p.role in ('rep', 'manager', 'executive')) then
    raise exception 'Sign in to use the cross-reference';
  end if;
  select jsonb_build_object('version', v.version, 'uploaded_at', v.uploaded_at,
           'rows', coalesce((select jsonb_agg(p.data order by p.position) from public.crossref_pairings p where p.version = v.version), '[]'::jsonb))
    into v_out
    from public.crossref_versions v where v.is_current limit 1;
  return coalesce(v_out, jsonb_build_object('version', null, 'rows', '[]'::jsonb));
end;
$function$;

create or replace function public.publish_crossref(p_version text, p_source text, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n integer;
begin
  if public.current_role_name() <> 'manager' then raise exception 'Only a manager can publish the cross-reference'; end if;
  p_version := nullif(trim(coalesce(p_version, '')), '');
  if p_version is null then raise exception 'Give the version a name (e.g. v27)'; end if;
  if exists (select 1 from public.crossref_versions where version = p_version) then raise exception 'Version % already exists', p_version; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'No pairings in the file'; end if;
  if exists (select 1 from jsonb_array_elements(p_rows) e
              where coalesce(trim(e->>'brand'), '') = '' or coalesce(trim(e->>'model'), '') = '' or coalesce(trim(e->>'audac'), '') = '') then
    raise exception 'Every pairing needs a brand, a competitor model and an AUDAC model';
  end if;
  insert into public.crossref_versions (version, source_name, pair_count) values (p_version, p_source, jsonb_array_length(p_rows));
  insert into public.crossref_pairings (version, position, data)
    select p_version, e.ord::int, e.val from jsonb_array_elements(p_rows) with ordinality as e(val, ord);
  get diagnostics v_n = row_count;
  update public.crossref_versions set is_current = (version = p_version) where is_current or version = p_version;
  return v_n;
end;
$function$;

create or replace function public.set_current_crossref(p_version text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if public.current_role_name() <> 'manager' then raise exception 'Only a manager can change the current cross-reference'; end if;
  if not exists (select 1 from public.crossref_versions where version = p_version) then raise exception 'Unknown version %', p_version; end if;
  update public.crossref_versions set is_current = (version = p_version) where is_current or version = p_version;
end;
$function$;

revoke all on function public.get_crossref() from public, anon;
revoke all on function public.publish_crossref(text, text, jsonb) from public, anon;
revoke all on function public.set_current_crossref(text) from public, anon;
grant execute on function public.get_crossref() to authenticated;
grant execute on function public.publish_crossref(text, text, jsonb) to authenticated;
grant execute on function public.set_current_crossref(text) to authenticated;
