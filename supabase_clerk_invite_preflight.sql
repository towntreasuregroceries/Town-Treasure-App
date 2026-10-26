-- Read-only check before applying supabase_clerk_invite_security.sql.
-- If unmapped_existing_rows is non-zero, stop and assign those rows to the
-- correct owner before applying the security migration.
SELECT
  COUNT(*) AS staged_rows,
  COUNT(*) FILTER (
    WHERE EXISTS (
      SELECT 1
      FROM auth.users AS u
      WHERE u.id::TEXT = s.target_user_id
         OR (
           s.target_user_email IS NOT NULL
           AND pg_catalog.lower(u.email) = pg_catalog.lower(s.target_user_email)
         )
    )
  ) AS rows_with_a_known_account,
  COUNT(*) FILTER (
    WHERE NOT EXISTS (
      SELECT 1
      FROM auth.users AS u
      WHERE u.id::TEXT = s.target_user_id
         OR (
           s.target_user_email IS NOT NULL
           AND pg_catalog.lower(u.email) = pg_catalog.lower(s.target_user_email)
         )
    )
  ) AS unmapped_existing_rows
FROM public.staged_invoices AS s;

-- If the summary reports unmapped rows, inspect their IDs and routing fields:
SELECT id, restaurant_name, created_at, target_user_id, target_user_email
FROM public.staged_invoices AS s
WHERE NOT EXISTS (
  SELECT 1
  FROM auth.users AS u
  WHERE u.id::TEXT = s.target_user_id
     OR (
       s.target_user_email IS NOT NULL
       AND pg_catalog.lower(u.email) = pg_catalog.lower(s.target_user_email)
     )
)
ORDER BY created_at;
