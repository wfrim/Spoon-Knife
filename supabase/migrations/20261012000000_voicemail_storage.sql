-- Voicemail audio in Supabase Storage: bucket "voicemails", objects at
-- <home id>/<call id>.m4a. The caller may upload only for their own call while
-- it's taking a message; roommates of the home may listen.
-- Skipped on plain Postgres (tests), where the storage schema doesn't exist.

do $outer$
begin
  if not exists (select 1 from pg_namespace where nspname = 'storage') then
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('voicemails', 'voicemails', false, 2 * 1024 * 1024, array['audio/mp4', 'audio/m4a', 'audio/x-m4a'])
  on conflict (id) do nothing;

  execute $p$
    create policy voicemail_upload on storage.objects for insert to authenticated
    with check (
      bucket_id = 'voicemails'
      and exists (
        select 1 from public.calls c
         where c.id::text = split_part(storage.filename(name), '.', 1)
           and c.apartment_id::text = (storage.foldername(name))[1]
           and c.caller_id = auth.uid()
           and c.state = 'voicemail'))
  $p$;

  execute $p$
    create policy voicemail_listen on storage.objects for select to authenticated
    using (
      bucket_id = 'voicemails'
      and public.is_member(((storage.foldername(name))[1])::uuid))
  $p$;
end
$outer$;
