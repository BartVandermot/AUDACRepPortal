-- ---------------------------------------------------------------------------
-- 1. Audit trail. Both managers and (as of the previous migration) reps can now
-- edit/delete activity_entries, so a bad edit or an accidental delete needs a
-- recoverable trail. Captures the full OLD row on every UPDATE/DELETE, plus who
-- did it and when. Nobody can write to this table directly -- only the trigger,
-- running as its owner (bypasses RLS the same way other definer functions do).
-- ---------------------------------------------------------------------------
create table public.activity_entries_audit (
  id uuid primary key default gen_random_uuid(),
  activity_entry_id uuid not null,
  action text not null check (action in ('update', 'delete')),
  changed_by uuid references auth.users(id),
  changed_by_email text,
  changed_at timestamptz not null default now(),
  old_data jsonb not null,
  new_data jsonb
);

create index idx_activity_entries_audit_entry_id on public.activity_entries_audit(activity_entry_id);
create index idx_activity_entries_audit_changed_at on public.activity_entries_audit(changed_at desc);

alter table public.activity_entries_audit enable row level security;
create policy "activity_entries_audit_select_staff" on public.activity_entries_audit
  for select using (public.current_role_name() in ('manager', 'executive'));

create or replace function public.log_activity_entry_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'UPDATE') then
    insert into public.activity_entries_audit (activity_entry_id, action, changed_by, changed_by_email, old_data, new_data)
    values (old.id, 'update', auth.uid(), (select email from auth.users where id = auth.uid()), to_jsonb(old), to_jsonb(new));
    return new;
  elsif (tg_op = 'DELETE') then
    insert into public.activity_entries_audit (activity_entry_id, action, changed_by, changed_by_email, old_data, new_data)
    values (old.id, 'delete', auth.uid(), (select email from auth.users where id = auth.uid()), to_jsonb(old), null);
    return old;
  end if;
  return null;
end;
$$;

create trigger activity_entries_audit_trigger
  after update or delete on public.activity_entries
  for each row execute function public.log_activity_entry_change();

-- ---------------------------------------------------------------------------
-- 2. Attachments. A rep can attach a photo (demo setup, business card, etc.)
-- to an activity entry. Files land in Storage; this table is just the metadata
-- + access-control anchor -- storage.objects RLS below cross-references it so
-- a rep can only reach files they uploaded (or, for managers/executives, any).
-- ---------------------------------------------------------------------------
create table public.activity_attachments (
  id uuid primary key default gen_random_uuid(),
  activity_entry_id uuid not null references public.activity_entries(id) on delete cascade,
  storage_path text not null unique,
  file_name text,
  content_type text,
  uploaded_by uuid references auth.users(id),
  uploaded_at timestamptz not null default now()
);

create index idx_activity_attachments_entry_id on public.activity_attachments(activity_entry_id);

alter table public.activity_attachments enable row level security;

create policy "activity_attachments_insert_public" on public.activity_attachments
  for insert with check (true);
create policy "activity_attachments_select_scoped" on public.activity_attachments
  for select using (public.current_role_name() in ('manager', 'executive') or uploaded_by = auth.uid());
create policy "activity_attachments_delete_scoped" on public.activity_attachments
  for delete using (public.current_role_name() = 'manager' or uploaded_by = auth.uid());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('activity-attachments', 'activity-attachments', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']);

-- Uploads happen after the activity_entries row already exists (path is
-- "<entry-id>/<filename>"), so upload is open the same way the entries
-- insert itself is -- mirrors the app's existing public-submission trust
-- model rather than introducing a stricter one just for files. Bucket-level
-- file_size_limit/allowed_mime_types above are the actual abuse guardrail
-- (enforced server-side), not this policy.
create policy "activity_attachments_storage_insert" on storage.objects
  for insert with check (bucket_id = 'activity-attachments');

create policy "activity_attachments_storage_select" on storage.objects
  for select using (
    bucket_id = 'activity-attachments' and (
      public.current_role_name() in ('manager', 'executive')
      or exists (
        select 1 from public.activity_attachments a
        where a.storage_path = storage.objects.name and a.uploaded_by = auth.uid()
      )
    )
  );

create policy "activity_attachments_storage_delete" on storage.objects
  for delete using (
    bucket_id = 'activity-attachments' and (
      public.current_role_name() = 'manager'
      or exists (
        select 1 from public.activity_attachments a
        where a.storage_path = storage.objects.name and a.uploaded_by = auth.uid()
      )
    )
  );
