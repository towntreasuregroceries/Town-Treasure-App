CREATE TABLE IF NOT EXISTS vault_meta (
  user_id TEXT PRIMARY KEY,
  revision INTEGER NOT NULL DEFAULT 0,
  r2_key TEXT NOT NULL,
  sha256 TEXT,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS vault_history (
  user_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  r2_key TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, revision)
);

CREATE TABLE IF NOT EXISTS clerk_invites (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  owner_email TEXT,
  owner_name TEXT NOT NULL DEFAULT 'Account owner',
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_clerk_invites_owner ON clerk_invites(owner_user_id);

CREATE TABLE IF NOT EXISTS staged_invoices (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  submitted_by_invite_id TEXT,
  submission_key TEXT,
  clerk_name TEXT NOT NULL DEFAULT 'Clerk',
  restaurant_name TEXT NOT NULL DEFAULT 'General Wholesale',
  invoice_date TEXT NOT NULL,
  items_json TEXT NOT NULL DEFAULT '[]',
  delivery_cost REAL NOT NULL DEFAULT 0,
  other_cost REAL NOT NULL DEFAULT 0,
  total_sell REAL NOT NULL DEFAULT 0,
  total_buy REAL NOT NULL DEFAULT 0,
  photo_keys_json TEXT NOT NULL DEFAULT '[]',
  notes TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending',
  rejection_reason TEXT NOT NULL DEFAULT '',
  target_user_id TEXT,
  target_user_email TEXT,
  target_user_name TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_staged_owner_created ON staged_invoices(owner_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_staged_status ON staged_invoices(status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_staged_invite_sub_key
  ON staged_invoices(owner_user_id, submitted_by_invite_id, submission_key)
  WHERE submitted_by_invite_id IS NOT NULL AND submission_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS oscu_sequences (
  tin TEXT NOT NULL,
  bhf_id TEXT NOT NULL,
  next_invc_no INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tin, bhf_id)
);

CREATE TABLE IF NOT EXISTS oscu_items (
  tin TEXT NOT NULL,
  item_cd TEXT NOT NULL,
  item_cls_cd TEXT NOT NULL,
  item_nm TEXT NOT NULL,
  tax_ty_cd TEXT NOT NULL DEFAULT 'A',
  synced_at TEXT NOT NULL,
  PRIMARY KEY (tin, item_cd)
);

CREATE TABLE IF NOT EXISTS clerk_rate_limits (
  invite_id TEXT NOT NULL,
  hour_bucket TEXT NOT NULL,
  submissions INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (invite_id, hour_bucket)
);

CREATE TABLE IF NOT EXISTS staged_pod_stamps (
  docket_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  pod_r2_key TEXT NOT NULL,
  receiver_name TEXT NOT NULL DEFAULT '',
  captured_at TEXT NOT NULL DEFAULT '',
  sha256 TEXT NOT NULL DEFAULT ''
);
