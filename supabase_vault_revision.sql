-- Town Treasure Groceries — encrypted vault revisions and compare-and-swap writes
-- Apply this in Supabase SQL Editor after deploying the client changes in data.js.
-- Existing encrypted_vault.data values are left intact. Existing rows begin at
-- revision 0 and are copied into the private history table as a recovery point.

BEGIN;

ALTER TABLE public.encrypted_vault
  ADD COLUMN IF NOT EXISTS revision BIGINT NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.encrypted_vault_history (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  revision BIGINT NOT NULL,
  data TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, revision)
);

ALTER TABLE public.encrypted_vault_history ENABLE ROW LEVEL SECURITY;

-- Keep the SECURITY DEFINER implementation outside the API-exposed public
-- schema. Do not add ttg_private to Supabase's exposed schemas.
CREATE SCHEMA IF NOT EXISTS ttg_private;
REVOKE ALL PRIVILEGES ON SCHEMA ttg_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA ttg_private TO authenticated;

-- Keep a private baseline of every vault currently present before any app write.
INSERT INTO public.encrypted_vault_history (user_id, revision, data)
SELECT user_id, revision, data
FROM public.encrypted_vault
ON CONFLICT (user_id, revision) DO NOTHING;

-- The app may read its own row, but all writes must go through the CAS function.
DROP POLICY IF EXISTS "Users can manage their own vault" ON public.encrypted_vault;
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

  -- Lock an existing row so only one writer can advance its revision at a time.
  SELECT revision, data
    INTO v_current_revision, v_current_data
    FROM public.encrypted_vault
    WHERE user_id = p_user_id
    FOR UPDATE;

  IF NOT FOUND THEN
    -- A missing live row is only treated as a new account if there is no
    -- retained history. If the row was deleted accidentally, fail closed so
    -- the client cannot recreate it from a possibly empty local cache.
    SELECT max(revision) INTO v_current_revision
      FROM public.encrypted_vault_history
      WHERE user_id = p_user_id;

    IF v_current_revision IS NOT NULL THEN
      RETURN pg_catalog.jsonb_build_object('saved', FALSE, 'revision', v_current_revision);
    END IF;

    IF p_expected_revision <> 0 THEN
      RETURN pg_catalog.jsonb_build_object('saved', FALSE, 'revision', 0);
    END IF;

    -- The primary key resolves two simultaneous first writes. A losing insert
    -- returns the revision that won so the client can reload and merge.
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

  -- Retain the prior encrypted snapshot before advancing the live row.
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

  -- Bound storage while retaining the latest 100 previous snapshots per user.
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

REVOKE ALL PRIVILEGES ON FUNCTION ttg_private.save_encrypted_vault_cas_internal(UUID, BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ttg_private.save_encrypted_vault_cas_internal(UUID, BIGINT, TEXT) TO authenticated;

-- PostgREST exposes only this invoker wrapper. The trusted implementation
-- runs with its owner's privileges and independently checks auth.uid().
CREATE OR REPLACE FUNCTION public.save_encrypted_vault_cas(
  p_user_id UUID,
  p_expected_revision BIGINT,
  p_data TEXT
)
RETURNS JSONB
LANGUAGE SQL
SECURITY INVOKER
SET search_path = ''
AS $wrapper$
  SELECT ttg_private.save_encrypted_vault_cas_internal($1, $2, $3);
$wrapper$;

REVOKE ALL PRIVILEGES ON FUNCTION public.save_encrypted_vault_cas(UUID, BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_encrypted_vault_cas(UUID, BIGINT, TEXT) TO authenticated;

COMMIT;
