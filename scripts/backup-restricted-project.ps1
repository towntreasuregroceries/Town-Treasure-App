param(
  [string]$ProjectRef = 'bulptzqaoddnptiwfrce'
)
$ErrorActionPreference = 'Stop'
$workspacePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$backupPath = Join-Path $workspacePath ('backups\recovery-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

# Limit the local backup to the signed-in Windows user and SYSTEM.
$acl = Get-Acl -LiteralPath $backupPath
$acl.SetAccessRuleProtection($true, $false)
$userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
foreach ($sid in @($userSid, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
  $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
  $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $backupPath -AclObject $acl

function Read-ProjectQuery([string]$Sql) {
  $queryPath = Join-Path $backupPath 'query.sql'
  [System.IO.File]::WriteAllText($queryPath, $Sql)
  $outputLines = & npx --yes supabase@3.0.0 db query "--remote=$ProjectRef" --read-only --file $queryPath --output json
  if ($LASTEXITCODE -ne 0) { throw 'Read-only backup query failed; existing files have been kept.' }
  $result = ($outputLines -join "`n") | ConvertFrom-Json
  if ($null -eq $result.rows) { throw 'Unrecognized query result; backup stopped.' }
  return $result.rows
}

$tables = @(
  @{ Name='public.encrypted_vault'; Order='user_id'; PageSize=10 },
  @{ Name='public.staged_invoices'; Order='id'; PageSize=5 },
  @{ Name='public.clerk_invites'; Order='id'; PageSize=100 },
  @{ Name='auth.users'; Order='id'; PageSize=100 },
  @{ Name='auth.identities'; Order='id'; PageSize=100 },
  @{ Name='public.encrypted_vault_history'; Order='user_id, revision'; PageSize=10 }
)
$manifest = [ordered]@{
  format='ttg-logical-rescue-v1'; project_ref=$ProjectRef
  started_at=[DateTime]::UtcNow.ToString('o'); complete=$false
  note='Private logical export, not a complete pg_dump. Live credentials, encryption passwords and external Storage objects are not recreated by this export.'
  tables=@(); files=@()
}

foreach ($table in $tables) {
  $tableName = $table.Name
  $order = $table.Order
  $pageSize = $table.PageSize
  # The fingerprint is recomputed after export. A concurrent change prevents
  # this backup being marked complete; it never causes a production write.
  $fingerprintSql = "SELECT count(*) AS row_count, md5(coalesce(string_agg(md5(to_jsonb(t)::text), '' ORDER BY $order), '')) AS fingerprint FROM $tableName t;"
  $before = @(Read-ProjectQuery $fingerprintSql)[0]
  $exported = 0
  for ($offset = 0; $offset -lt $before.row_count; $offset += $pageSize) {
    $sql = "SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) AS records FROM (SELECT * FROM $tableName ORDER BY $order LIMIT $pageSize OFFSET $offset) t;"
    $rows = @(Read-ProjectQuery $sql)
    $records = @($rows[0].records)
    $filename = ($tableName.Replace('.', '_') + '-' + $offset.ToString('D6') + '.json')
    $filePath = Join-Path $backupPath $filename
    $json = ConvertTo-Json -InputObject $records -Depth 100 -Compress
    [System.IO.File]::WriteAllText($filePath, $json)
    $readback = [System.IO.File]::ReadAllText($filePath) | ConvertFrom-Json
    if (@($readback).Count -ne $records.Count) { throw "Backup readback failed for $tableName." }
    $exported += $records.Count
    $manifest.files += [ordered]@{ file=$filename; table=$tableName; rows=$records.Count; bytes=(Get-Item -LiteralPath $filePath).Length; sha256=(Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash }
  }
  $after = @(Read-ProjectQuery $fingerprintSql)[0]
  if ($exported -ne $before.row_count -or $after.fingerprint -ne $before.fingerprint) {
    throw "The $tableName table changed during export. Files are preserved, but this backup is not marked complete."
  }
  $manifest.tables += [ordered]@{ table=$tableName; rows=$exported; fingerprint=$before.fingerprint; stable=$true }
  Write-Output "Backed up $tableName ($exported rows)."
}

# Record schema, row security and function definitions for a reviewed restore.
$schemaSql = @'
SELECT jsonb_build_object(
  'columns', (SELECT jsonb_agg(to_jsonb(c)) FROM information_schema.columns c WHERE table_schema IN ('public','ttg_private','auth')),
  'constraints', (SELECT jsonb_agg(jsonb_build_object('table', conrelid::regclass::text, 'name', conname, 'definition', pg_get_constraintdef(oid))) FROM pg_constraint WHERE connamespace IN (SELECT oid FROM pg_namespace WHERE nspname IN ('public','ttg_private','auth'))),
  'indexes', (SELECT jsonb_agg(to_jsonb(i)) FROM pg_indexes i WHERE schemaname IN ('public','ttg_private','auth')),
  'policies', (SELECT jsonb_agg(to_jsonb(p)) FROM pg_policies p WHERE schemaname IN ('public','ttg_private')),
  'grants', (SELECT jsonb_agg(to_jsonb(g)) FROM information_schema.role_table_grants g WHERE table_schema IN ('public','ttg_private')),
  'functions', (SELECT jsonb_agg(jsonb_build_object('schema', n.nspname, 'name', p.proname, 'definition', pg_get_functiondef(p.oid))) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('public','ttg_private') AND p.prokind='f')
) AS schema;
'@
$schemaRows = @(Read-ProjectQuery $schemaSql)
$schemaPath = Join-Path $backupPath 'schema.json'
[System.IO.File]::WriteAllText($schemaPath, (ConvertTo-Json -InputObject $schemaRows[0].schema -Depth 100 -Compress))
$manifest.files += [ordered]@{ file='schema.json'; bytes=(Get-Item -LiteralPath $schemaPath).Length; sha256=(Get-FileHash -LiteralPath $schemaPath -Algorithm SHA256).Hash }

# Check the whole export interval as well as each individual table.
foreach ($entry in $manifest.tables) {
  $order = ($tables | Where-Object { $_.Name -eq $entry.table }).Order
  $sql = "SELECT md5(coalesce(string_agg(md5(to_jsonb(t)::text), '' ORDER BY $order), '')) AS fingerprint FROM $($entry.table) t;"
  $final = @(Read-ProjectQuery $sql)[0]
  if ($final.fingerprint -ne $entry.fingerprint) { throw 'Source changed during backup. Files retained; retry before migration.' }
}
$manifest.complete = $true
$manifest.finished_at = [DateTime]::UtcNow.ToString('o')
[System.IO.File]::WriteAllText((Join-Path $backupPath 'manifest.json'), (ConvertTo-Json -InputObject $manifest -Depth 10))
Write-Output "Verified logical rescue backup: $backupPath"
