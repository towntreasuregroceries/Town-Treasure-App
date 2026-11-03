-- Town Treasure Groceries — Project Schema Initialization
BEGIN;

-- 1. Encrypted Vault
CREATE TABLE IF NOT EXISTS public.encrypted_vault (
  user_id UUID NOT NULL PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  revision BIGINT NOT NULL DEFAULT 0,
  data TEXT NOT NULL
);
ALTER TABLE public.encrypted_vault ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.encrypted_vault_history (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  revision BIGINT NOT NULL,
  data TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, revision)
);
ALTER TABLE public.encrypted_vault_history ENABLE ROW LEVEL SECURITY;

-- 2. Schema ttg_private and Guarded CAS Functions
CREATE SCHEMA IF NOT EXISTS ttg_private;
REVOKE ALL PRIVILEGES ON SCHEMA ttg_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA ttg_private TO authenticated;

DROP POLICY IF EXISTS "Users can read their own vault" ON public.encrypted_vault;
CREATE POLICY "Users can read their own vault"
  ON public.encrypted_vault
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

REVOKE ALL PRIVILEGES ON TABLE public.encrypted_vault FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.encrypted_vault TO authenticated;
REVOKE ALL PRIVILEGES ON TABLE public.encrypted_vault_history FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION ttg_private.save_encrypted_vault_cas_internal(
  p_user_id UUID,
  p_expected_revision BIGINT,
  p_data TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_current_revision BIGINT;
  v_current_data TEXT;
  v_next_revision BIGINT;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Not authorized to write this encrypted vault.'
      USING ERRCODE = '42501';
  END IF;

  IF p_expected_revision IS NULL OR p_expected_revision < 0 OR p_data IS NULL OR p_data = '' THEN
    RAISE EXCEPTION 'Invalid vault revision or payload.'
      USING ERRCODE = '22023';
  END IF;

  SELECT revision, data
    INTO v_current_revision, v_current_data
    FROM public.encrypted_vault
    WHERE user_id = p_user_id
    FOR UPDATE;

  IF NOT FOUND THEN
    SELECT max(revision) INTO v_current_revision
      FROM public.encrypted_vault_history
      WHERE user_id = p_user_id;

    IF v_current_revision IS NOT NULL THEN
      RETURN pg_catalog.jsonb_build_object('saved', FALSE, 'revision', v_current_revision);
    END IF;

    IF p_expected_revision <> 0 THEN
      RETURN pg_catalog.jsonb_build_object('saved', FALSE, 'revision', 0);
    END IF;

    INSERT INTO public.encrypted_vault (user_id, data, revision)
      VALUES (p_user_id, p_data, 1)
      ON CONFLICT (user_id) DO NOTHING
      RETURNING revision INTO v_next_revision;

    IF FOUND THEN
      RETURN pg_catalog.jsonb_build_object('saved', TRUE, 'revision', v_next_revision);
    END IF;

    SELECT revision INTO v_current_revision
      FROM public.encrypted_vault
      WHERE user_id = p_user_id;
    RETURN pg_catalog.jsonb_build_object('saved', FALSE, 'revision', COALESCE(v_current_revision, 0));
  END IF;

  IF v_current_revision <> p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object('saved', FALSE, 'revision', v_current_revision);
  END IF;

  INSERT INTO public.encrypted_vault_history (user_id, revision, data)
    VALUES (p_user_id, v_current_revision, v_current_data)
    ON CONFLICT (user_id, revision) DO NOTHING;

  UPDATE public.encrypted_vault
    SET data = p_data,
        revision = v_current_revision + 1
    WHERE user_id = p_user_id
      AND revision = v_current_revision
    RETURNING revision INTO v_next_revision;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Vault changed during the guarded write.'
      USING ERRCODE = '40001';
  END IF;

  DELETE FROM public.encrypted_vault_history
    WHERE user_id = p_user_id
      AND revision NOT IN (
        SELECT revision
          FROM public.encrypted_vault_history
          WHERE user_id = p_user_id
          ORDER BY revision DESC
          LIMIT 100
      );

  RETURN pg_catalog.jsonb_build_object('saved', TRUE, 'revision', v_next_revision);
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_encrypted_vault_cas(
  p_user_id UUID,
  p_expected_revision BIGINT,
  p_data TEXT
)
RETURNS JSONB
LANGUAGE sql
SET search_path = ''
AS $function$
  SELECT ttg_private.save_encrypted_vault_cas_internal($1, $2, $3);
$function$;

-- 3. Clerk Invites
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

-- 4. Staged Invoices
CREATE TABLE IF NOT EXISTS public.staged_invoices (
  id TEXT PRIMARY KEY,
  clerk_name TEXT NOT NULL DEFAULT 'Clerk',
  restaurant_name TEXT NOT NULL DEFAULT 'General Wholesale',
  invoice_date DATE NOT NULL DEFAULT CURRENT_DATE,
  items_json JSONB NOT NULL DEFAULT '[]'::jsonb,
  delivery_cost NUMERIC DEFAULT 0,
  other_cost NUMERIC DEFAULT 0,
  total_sell NUMERIC DEFAULT 0,
  total_buy NUMERIC DEFAULT 0,
  receipt_photo TEXT,
  receipt_photos JSONB DEFAULT '[]'::jsonb,
  notes TEXT,
  target_user_id TEXT,
  target_user_email TEXT,
  target_user_name TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  rejection_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  owner_user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  submitted_by_invite_id UUID REFERENCES public.clerk_invites(id) ON DELETE SET NULL,
  submission_key TEXT
);
ALTER TABLE public.staged_invoices ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_staged_invoices_status ON public.staged_invoices(status);
CREATE INDEX IF NOT EXISTS idx_staged_invoices_created ON public.staged_invoices(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_staged_invoices_target_uid ON public.staged_invoices(target_user_id);
CREATE INDEX IF NOT EXISTS idx_staged_invoices_target_email ON public.staged_invoices(target_user_email);
CREATE UNIQUE INDEX IF NOT EXISTS idx_staged_invoices_invite_submission_key
  ON public.staged_invoices (owner_user_id, submitted_by_invite_id, submission_key)
  WHERE submitted_by_invite_id IS NOT NULL AND submission_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_staged_invoices_owner_created
  ON public.staged_invoices (owner_user_id, created_at DESC);

DROP POLICY IF EXISTS "Owners can delete their staged invoices" ON public.staged_invoices;
CREATE POLICY "Owners can delete their staged invoices"
  ON public.staged_invoices FOR DELETE TO authenticated
  USING (owner_user_id = (SELECT auth.uid() AS uid));

DROP POLICY IF EXISTS "Owners can insert their staged invoices" ON public.staged_invoices;
CREATE POLICY "Owners can insert their staged invoices"
  ON public.staged_invoices FOR INSERT TO authenticated
  WITH CHECK (owner_user_id = (SELECT auth.uid() AS uid));

DROP POLICY IF EXISTS "Owners can read their staged invoices" ON public.staged_invoices;
CREATE POLICY "Owners can read their staged invoices"
  ON public.staged_invoices FOR SELECT TO authenticated
  USING (owner_user_id = (SELECT auth.uid() AS uid));

DROP POLICY IF EXISTS "Owners can update their staged invoices" ON public.staged_invoices;
CREATE POLICY "Owners can update their staged invoices"
  ON public.staged_invoices FOR UPDATE TO authenticated
  USING (owner_user_id = (SELECT auth.uid() AS uid))
  WITH CHECK (owner_user_id = (SELECT auth.uid() AS uid));

COMMIT;

