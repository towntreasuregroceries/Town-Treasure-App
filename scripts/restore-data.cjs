const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const backupDir = path.join(__dirname, '..', 'backups', 'recovery-20261103-123725-a3009db7');
const projectRef = 'hufxsjfmgjeyfdidsvcq';

function escapeSqlVal(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') return String(v);
  if (typeof v === 'object') return `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`;
  return `'${String(v).replace(/'/g, "''")}'`;
}

function buildInsertSql(tableName, records, onConflictKey = null, ignoreCols = []) {
  if (!records.length) return '';
  let sql = 'BEGIN;\n';
  for (const r of records) {
    const cols = Object.keys(r).filter(c => !ignoreCols.includes(c));
    const vals = cols.map(c => escapeSqlVal(r[c]));
    let stmt = `INSERT INTO ${tableName} (${cols.map(c => `"${c}"`).join(', ')}) VALUES (${vals.join(', ')})`;
    if (onConflictKey) {
      stmt += ` ON CONFLICT (${onConflictKey}) DO NOTHING`;
    }
    sql += stmt + ';\n';
  }
  sql += 'COMMIT;\n';
  return sql;
}

function runSql(sql, label) {
  const tmpFile = path.join(__dirname, '..', 'scratch', `run_${Date.now()}.sql`);
  fs.writeFileSync(tmpFile, sql, 'utf8');
  console.log(`Running ${label}... (${(sql.length / 1024).toFixed(1)} KB)`);
  try {
    const out = execSync(`npx supabase db query --remote=${projectRef} --file "${tmpFile}" --yes --output json`, {
      encoding: 'utf8',
      timeout: 120000
    });
    console.log(`✔ Finished ${label}`);
  } finally {
    if (fs.existsSync(tmpFile)) fs.unlinkSync(tmpFile);
  }
}

// 1. Auth Users
const users = JSON.parse(fs.readFileSync(path.join(backupDir, 'auth_users-000000.json'), 'utf8'));
runSql(buildInsertSql('auth.users', users, 'id', ['confirmed_at']), 'auth.users (4 rows)');

// 2. Auth Identities
const identities = JSON.parse(fs.readFileSync(path.join(backupDir, 'auth_identities-000000.json'), 'utf8'));
runSql(buildInsertSql('auth.identities', identities, 'id', ['email']), 'auth.identities (4 rows)');

// 3. Clerk Invites
const invites = JSON.parse(fs.readFileSync(path.join(backupDir, 'public_clerk_invites-000000.json'), 'utf8'));
runSql(buildInsertSql('public.clerk_invites', invites, 'id'), 'public.clerk_invites (7 rows)');

// 4. Encrypted Vault
const vaults = JSON.parse(fs.readFileSync(path.join(backupDir, 'public_encrypted_vault-000000.json'), 'utf8'));
runSql(buildInsertSql('public.encrypted_vault', vaults, 'user_id'), 'public.encrypted_vault (3 rows)');

// 5. Staged Invoices - row by row to stay under payload limits
const stagedFiles = fs.readdirSync(backupDir).filter(f => f.startsWith('public_staged_invoices-') && f.endsWith('.json'));
let totalStaged = 0;
for (const file of stagedFiles) {
  const staged = JSON.parse(fs.readFileSync(path.join(backupDir, file), 'utf8'));
  for (const row of staged) {
    totalStaged++;
    runSql(buildInsertSql('public.staged_invoices', [row], 'id'), `public.staged_invoices [${totalStaged}/18] (id: ${row.id.substring(0,8)})`);
  }
}

console.log('✅ Core data restoration complete! Total staged invoices restored:', totalStaged);
