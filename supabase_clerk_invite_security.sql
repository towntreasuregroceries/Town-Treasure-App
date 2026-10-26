-- Secure link-only clerk intake.
-- Apply only after the clerk-api Edge Function is deployed and configured.
-- The app's anon key remains public; access is controlled by this migration
-- plus the server-verified, expiring invite token.

BEGIN;

CREATE TABLE IF NOT EXISTS public.clerk_invites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  owner_email TEXT,
  owner_name TEXT NOT NULL DEFAULT 'Account owner',
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE public.clerk_invites ENABLE ROW LEVEL SECURITY;
REVOKE ALL PRIVILEGES ON TABLE public.clerk_invites FROM PUBLIC, anon, authenticated;
GRANT ALL PRIVILEGES ON TABLE public.clerk_invites TO service_role;

ALTER TABLE public.staged_invoices
  ADD COLUMN IF NOT EXISTS owner_user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS submitted_by_invite_id UUID REFERENCES public.clerk_invites(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS submission_key TEXT,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Preserve existing rows by deriving ownership only from an exact account ID
-- or email already stored on the docket. No ambiguous ownership is guessed.
UPDATE public.staged_invoices AS s
SET owner_user_id = u.id
FROM auth.users AS u
WHERE s.owner_user_id IS NULL
  AND pg_catalog.lower(s.target_user_id) = pg_catalog.lower(u.id::TEXT);

UPDATE public.staged_invoices AS s
SET owner_user_id = u.id
FROM auth.users AS u
WHERE s.owner_user_id IS NULL
  AND s.target_user_email IS NOT NULL
  AND pg_catalog.lower(s.target_user_email) = pg_catalog.lower(u.email);

DO $migration$
DECLARE
  v_unassigned BIGINT;
BEGIN
  SELECT pg_catalog.count(*) INTO v_unassigned
  FROM public.staged_invoices
  WHERE owner_user_id IS NULL;

  IF v_unassigned > 0 THEN
    RAISE EXCEPTION 'Clerk security migration stopped: % existing staged invoice(s) could not be safely assigned to an account. Assign owner_user_id for those rows, then rerun.', v_unassigned;
  END IF;
END;
$migration$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_staged_invoices_invite_submission_key
  ON public.staged_invoices (owner_user_id, submitted_by_invite_id, submission_key)
  WHERE submitted_by_invite_id IS NOT NULL AND submission_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_staged_invoices_owner_created
  ON public.staged_invoices (owner_user_id, created_at DESC);

-- Remove every existing policy, including unknown permissive policies that
-- would otherwise combine with the restrictive policies below.
DO $policies$
DECLARE
  policy_row RECORD;
BEGIN
  FOR policy_row IN
    SELECT policyname
    FROM pg_catalog.pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'staged_invoices'
  LOOP
    EXECUTE pg_catalog.format('DROP POLICY %I ON public.staged_invoices', policy_row.policyname);
  END LOOP;
END;
$policies$;

ALTER TABLE public.staged_invoices ENABLE ROW LEVEL SECURITY;
REVOKE ALL PRIVILEGES ON TABLE public.staged_invoices FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.staged_invoices TO authenticated;
GRANT ALL PRIVILEGES ON TABLE public.staged_invoices TO service_role;

CREATE POLICY "Owners can read their staged invoices"
  ON public.staged_invoices FOR SELECT TO authenticated
  USING (owner_user_id = (SELECT auth.uid()));

CREATE POLICY "Owners can insert their staged invoices"
  ON public.staged_invoices FOR INSERT TO authenticated
  WITH CHECK (owner_user_id = (SELECT auth.uid()));

CREATE POLICY "Owners can update their staged invoices"
  ON public.staged_invoices FOR UPDATE TO authenticated
  USING (owner_user_id = (SELECT auth.uid()))
  WITH CHECK (owner_user_id = (SELECT auth.uid()));

CREATE POLICY "Owners can delete their staged invoices"
  ON public.staged_invoices FOR DELETE TO authenticated
  USING (owner_user_id = (SELECT auth.uid()));

COMMIT;
