-- Read-only verification after supabase_clerk_invite_security.sql.
SELECT policyname, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'staged_invoices'
ORDER BY policyname;

SELECT grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN ('staged_invoices', 'clerk_invites')
  AND grantee IN ('PUBLIC', 'anon', 'authenticated', 'service_role')
ORDER BY table_name, grantee, privilege_type;

SELECT
  COUNT(*) AS staged_invoice_rows,
  COUNT(*) FILTER (WHERE owner_user_id IS NULL) AS rows_without_owner
FROM public.staged_invoices;
