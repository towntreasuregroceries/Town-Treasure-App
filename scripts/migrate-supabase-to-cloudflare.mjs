#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const WORKER_BASE = (
  process.env.TTG_API_URL || 'https://ttg-api.towntreasuregroceries.workers.dev'
).replace(/\/+$/, '');
const REPO_ROOT = path.resolve(import.meta.dirname, '..');
const SECRET_FILE = path.join(REPO_ROOT, 'scratch', 'migration-secret.txt');

function loadMigrationSecret() {
  const fromEnv = (process.env.MIGRATION_SECRET || '').trim();
  if (fromEnv) return fromEnv;
  if (fs.existsSync(SECRET_FILE)) {
    const val = fs.readFileSync(SECRET_FILE, 'utf8').trim();
    if (val) return val;
  }
  throw new Error(
    'Missing MIGRATION_SECRET (set env var or provide scratch/migration-secret.txt).',
  );
}

function findSupabaseBinary() {
  if (process.platform === 'win32' && process.env.LOCALAPPDATA) {
    const npxCache = path.join(process.env.LOCALAPPDATA, 'npm-cache', '_npx');
    if (fs.existsSync(npxCache)) {
      for (const entry of fs.readdirSync(npxCache)) {
        const candidate = path.join(
          npxCache,
          entry,
          'node_modules',
          '@supabase',
          'cli-windows-x64',
          'bin',
          'supabase.exe',
        );
        if (fs.existsSync(candidate)) {
          return { bin: candidate, prefixArgs: [] };
        }
      }
    }
  }
  return {
    bin: process.platform === 'win32' ? 'npx.cmd' : 'npx',
    prefixArgs: ['--yes', 'supabase'],
  };
}

const SUPABASE_CMD = findSupabaseBinary();

function querySupabase(sql) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ttg-mig-'));
  const sqlFile = path.join(tmpDir, 'query.sql');
  fs.writeFileSync(sqlFile, sql, 'utf8');
  try {
    const res = spawnSync(
      SUPABASE_CMD.bin,
      [
        ...SUPABASE_CMD.prefixArgs,
        'db',
        'query',
        '--remote',
        '--read-only',
        '--agent',
        'yes',
        '--file',
        sqlFile,
      ],
      {
        cwd: REPO_ROOT,
        encoding: 'utf8',
        maxBuffer: 128 * 1024 * 1024,
        shell: false,
      },
    );
    if (res.error) throw res.error;
    if (res.status !== 0) {
      throw new Error(
        `supabase db query failed (exit ${res.status}): ${(res.stderr || res.stdout || '').slice(0, 800)}`,
      );
    }
    const raw = (res.stdout || '').trim();
    const jsonStart = raw.indexOf('{');
    if (jsonStart < 0) {
      throw new Error(`Unexpected non-JSON output from supabase db query: ${raw.slice(0, 400)}`);
    }
    const parsed = JSON.parse(raw.slice(jsonStart));
    return Array.isArray(parsed.rows) ? parsed.rows : [];
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

function sqlLiteral(val) {
  return `'${String(val).replaceAll("'", "''")}'`;
}

async function seedBatch(secret, type, rows) {
  if (!rows.length) return 0;
  let lastErr;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const res = await fetch(`${WORKER_BASE}/admin/seed`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Migration-Secret': secret,
        },
        body: JSON.stringify({ type, rows }),
      });
      const text = await res.text();
      let json = null;
      try {
        json = JSON.parse(text);
      } catch (_) {}
      if (!res.ok || !json?.ok) {
        throw new Error(
          `HTTP ${res.status} seeding ${type}: ${json?.error || text.slice(0, 300)}`,
        );
      }
      if (json.processed !== rows.length) {
        throw new Error(
          `Seed count mismatch for ${type}: sent=${rows.length}, processed=${json.processed}`,
        );
      }
      return json.processed;
    } catch (err) {
      lastErr = err;
      if (attempt < 3) {
        await new Promise((r) => setTimeout(r, attempt * 1200));
      }
    }
  }
  throw lastErr;
}

async function main() {
  const secret = loadMigrationSecret();
  const dryRun = process.argv.includes('--dry-run');
  const historyLimitArg = process.argv.find((a) => a.startsWith('--history-limit='));
  const historyLimit = historyLimitArg
    ? Math.max(0, Number(historyLimitArg.split('=')[1]) || 25)
    : 25;

  console.log(`Target Worker: ${WORKER_BASE}${dryRun ? ' [DRY RUN]' : ''}`);
  console.log(`Supabase CLI: ${SUPABASE_CMD.bin}`);

  // 1. Live Vaults
  const vaultUsers = querySupabase(
    'SELECT user_id, revision FROM encrypted_vault ORDER BY user_id;',
  );
  console.log(`Found ${vaultUsers.length} vault row(s) in Supabase.`);
  let seededVaults = 0;
  let seededHistory = 0;

  for (const u of vaultUsers) {
    const uid = String(u.user_id);
    const full = querySupabase(
      `SELECT user_id, revision, data FROM encrypted_vault WHERE user_id = ${sqlLiteral(uid)};`,
    );
    if (full.length) {
      const byteLen = String(full[0].data || '').length;
      console.log(
        `  Vault user=${uid.slice(0, 8)}... rev=${full[0].revision} payload=${(byteLen / 1024).toFixed(1)} KB`,
      );
      if (!dryRun) {
        seededVaults += await seedBatch(secret, 'vault', [
          { ...full[0], updated_at: new Date().toISOString() },
        ]);
      }
    }

    // 2. Latest N vault history snapshots (fetch 5 per SQL query, upload 1 per HTTP call)
    if (historyLimit > 0) {
      const revs = querySupabase(
        `SELECT revision FROM encrypted_vault_history WHERE user_id = ${sqlLiteral(uid)} ORDER BY revision DESC LIMIT ${historyLimit};`,
      );
      console.log(
        `  Migrating ${revs.length} history snapshot(s) for user=${uid.slice(0, 8)}...`,
      );
      for (let i = 0; i < revs.length; i += 5) {
        const revNums = revs.slice(i, i + 5).map((r) => Number(r.revision));
        const snaps = querySupabase(
          `SELECT user_id, revision, data, created_at FROM encrypted_vault_history WHERE user_id = ${sqlLiteral(uid)} AND revision IN (${revNums.join(',')});`,
        );
        if (!dryRun) {
          for (const snap of snaps) {
            seededHistory += await seedBatch(secret, 'vault_history', [snap]);
          }
        }
        console.log(
          `    History progress (${uid.slice(0, 8)}...): ${Math.min(i + 5, revs.length)}/${revs.length}`,
        );
      }
    }
  }

  // 3. Clerk invites
  const invites = querySupabase(
    'SELECT id, owner_user_id, token_hash, owner_email, owner_name, expires_at, revoked_at, created_at FROM clerk_invites ORDER BY created_at ASC;',
  );
  console.log(`Found ${invites.length} clerk_invites row(s) in Supabase.`);
  let seededInvites = 0;
  if (!dryRun && invites.length) {
    for (let i = 0; i < invites.length; i += 25) {
      seededInvites += await seedBatch(secret, 'clerk_invites', invites.slice(i, i + 25));
    }
  }

  // 4. Staged invoices (query 5 IDs at a time from Postgres, upload 1-2 per HTTP call so R2 photo upload stays smooth)
  const stagedIds = querySupabase(
    'SELECT id FROM staged_invoices ORDER BY created_at ASC, id ASC;',
  );
  console.log(`Found ${stagedIds.length} staged_invoices row(s) in Supabase.`);
  let seededStaged = 0;
  for (let i = 0; i < stagedIds.length; i += 5) {
    const batchIds = stagedIds.slice(i, i + 5).map((r) => sqlLiteral(r.id));
    const rows = querySupabase(
      `SELECT id, owner_user_id, submitted_by_invite_id, submission_key, clerk_name, restaurant_name, invoice_date, items_json, delivery_cost, other_cost, total_sell, total_buy, receipt_photo, receipt_photos, notes, status, rejection_reason, target_user_id, target_user_email, target_user_name, created_at, updated_at FROM staged_invoices WHERE id IN (${batchIds.join(',')});`,
    );
    if (!dryRun) {
      for (const row of rows) {
        seededStaged += await seedBatch(secret, 'staged_invoices', [row]);
      }
    }
    console.log(
      `  Staged progress: ${Math.min(i + 5, stagedIds.length)}/${stagedIds.length}`,
    );
  }

  console.log('Migration complete:', {
    dryRun,
    seededVaults,
    seededHistory,
    seededInvites,
    seededStaged,
  });
}

main().catch((err) => {
  console.error('MIGRATION FAILED:', err);
  process.exit(1);
});
