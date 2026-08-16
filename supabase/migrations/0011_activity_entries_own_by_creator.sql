-- Lets a rep who signs in (via passwordless magic link on the public form) see
-- and correct their own past submissions, without needing a profiles row, a
-- role, or any change to the existing manager/executive auth flow. Ownership is
-- just "the auth.uid() that created this row" -- nothing about role or firm.
alter table public.activity_entries add column created_by uuid references auth.users(id);

create policy "activity_entries_select_own" on public.activity_entries
  for select using (created_by = auth.uid());
create policy "activity_entries_update_own" on public.activity_entries
  for update using (created_by = auth.uid());
create policy "activity_entries_delete_own" on public.activity_entries
  for delete using (created_by = auth.uid());

-- Note: activity_entries_insert_public (with_check = true, roles = public) already
-- covers authenticated inserts too -- no new insert policy needed. The client sets
-- created_by = auth.uid() on insert when a rep is signed in; anonymous submissions
-- keep created_by null exactly as before, fully backward compatible.
