-- Read-only sizing audit. Does not return invoices, images, credentials or keys.
-- Run in SQL Editor, or: supabase db query --remote --read-only --file <this file>
SELECT jsonb_build_object(
  'captured_at', now(),
  'database_bytes', pg_database_size(current_database()),
  'user_count', (SELECT count(*) FROM auth.users),
  'vault', (SELECT jsonb_build_object(
    'accounts', count(*),
    'payload_bytes', coalesce(sum(octet_length(data)), 0),
    'largest_payload_bytes', coalesce(max(octet_length(data)), 0),
    'highest_revision', coalesce(max(revision), 0)
  ) FROM public.encrypted_vault),
  'history', (SELECT jsonb_build_object(
    'snapshots', count(*),
    'payload_bytes', coalesce(sum(octet_length(data)), 0)
  ) FROM public.encrypted_vault_history),
  'staging', (SELECT jsonb_build_object(
    'rows', count(*),
    'pending', count(*) FILTER (WHERE status = 'pending'),
    'approved', count(*) FILTER (WHERE status = 'approved'),
    'returned', count(*) FILTER (WHERE status = 'rejected'),
    'rows_without_owner', count(*) FILTER (WHERE owner_user_id IS NULL),
    'photo_bytes', coalesce(sum(octet_length(coalesce(receipt_photo, ''))
      + octet_length(coalesce(receipt_photos::text, ''))), 0),
    'duplicated_first_photo_bytes', coalesce(sum(CASE
      WHEN receipt_photo = receipt_photos ->> 0 THEN octet_length(receipt_photo) ELSE 0 END), 0),
    'full_row_json_bytes', coalesce(sum(octet_length(row_to_json(s)::text)), 0),
    'summary_json_bytes', coalesce(sum(octet_length((to_jsonb(s) - 'receipt_photo' - 'receipt_photos')::text)), 0)
  ) FROM public.staged_invoices s),
  'tables', (SELECT jsonb_agg(t) FROM (
    SELECT c.relname AS name, pg_total_relation_size(c.oid) AS total_bytes,
      c.relrowsecurity AS row_security_enabled
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
    ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 20
  ) t),
  'revision_guard_installed', to_regprocedure('public.save_encrypted_vault_cas(uuid,bigint,text)') IS NOT NULL
) AS audit;
