# Database recovery and zero-subscription-cost plan

Reviewed 3 November 2026 (Africa/Nairobi).

## Current incident

The app displays `exceed_egress_quota` at sign-in. This is a Supabase service
restriction. Client changes cannot clear that restriction or refund past usage.
The administrative API still permits read-only database queries. The database
was inspected through that API, rather than inferred from an old screenshot.

The public GitHub Pages app is at:
https://towntreasuregroceries.github.io/Town-Treasure-App/

The site was already serving commit ca95655's badge polling change on inspection.
GitHub Pages can deploy a branch without a workflow file in this repository;
the earlier suggestion that a missing workflow meant deployment was missing
was not sufficient evidence. The clerk page still referenced staging.js v1.3.2;
both pages now receive the same updated script version.

## Measured inventory

The read-only inventory at 09:35 UTC on 3 November returned:

| Item | Measured value |
| --- | ---: |
| Auth users | 4 |
| Current encrypted account vaults | 3 |
| Combined current encrypted payloads | 1,657,708 bytes |
| Largest current encrypted payload | 915,124 bytes |
| Highest current revision | 457 |
| Retained prior vault snapshots | 179 |
| Prior snapshots' encrypted payloads | 144,496,224 bytes |
| Staged dockets | 18 |
| Approved / pending / returned | 17 / 0 / 1 |
| Dockets without an owner | 0 |
| Full docket rows as JSON | 9,758,726 bytes |
| Docket rows excluding receipt fields | 40,044 bytes |
| Receipt image fields | 9,718,716 bytes |
| First images duplicated in both receipt fields | 4,859,323 bytes |
| Total database size, including indexes and other schemas | 199,322,771 bytes |

These are database payload sizes, not measured compressed HTTP wire bytes.
Metadata-only docket responses reduce this particular logical payload by about
99.6%. A full 9.76 MB list every 30 seconds is about 1.17 GB/hour per open tab,
before transport overhead/compression. This demonstrates the old amplification;
it does not attribute every byte on the billing dashboard to that query.

The encrypted vault's invoice counts and monetary totals cannot be verified
from SQL. Decryption with the owner's existing key is necessary. Old
`recovered_*.json` files from October are not current recovery sources.

## Recovery copy

`scripts/backup-restricted-project.ps1` exports the current vaults, all retained
vault history, staged dockets including photos, invites, auth users and auth
identities through read-only management queries. It also records schema,
constraint, index, policy, grant and application function definitions.

The private exports go to a unique `backups/recovery-*` directory. That directory
is excluded from Git and restricted to the Windows user and SYSTEM. Auth exports
and docket photos are sensitive. Never attach the backup to a public issue or
commit it. Keep a second protected copy on a separate drive before migration.

The script verifies each file can be parsed, records SHA-256 file checksums and
row counts, and compares table fingerprints before and after export. A complete
manifest is written only when every source table remained unchanged throughout
the export. This is a logical rescue copy, not a full pg_dump or a completed
restore rehearsal. Passwords/encryption keys are not supplied by the backup;
preserve the original owner's encryption password and user UUID.

No live rows need to be deleted to reduce egress. Keep current snapshots and
the recovery copy until a separate restore has been checked. Do not clear phone
storage or reset an account's password as an outage workaround.

## Changes prepared for the existing free project

1. Read the small server revision before deciding whether to download the vault.
   Reuse ciphertext only for the same user and the exact revision just returned
   by the server. Never use a local invoice collection as a remote snapshot.
2. Keep the existing compare-and-swap write, merge rules, encryption, history,
   deletion tombstones and conflict retries. Download again when another device
   changes the revision. Fail closed on a blocked or failed server request.
3. Return docket details without receipt fields for listing and duplicate checks.
   Fetch the full row, including photos, by ID when opening/correcting a docket.
4. Apply the same optional list/detail parameters to the invite API while
   preserving responses expected by older clients. The API keeps its owner and
   invite filters for every request.
5. Publish matching script versions for the owner and clerk pages. Existing
   visible-owner-only badge polling remains at two minutes.

These changes need no schema migration and do not replace stored records.
The existing whole-account upload still happens on saves; this release reduces
downloads, not all database work. Auth remains dependent on Supabase service
availability. The write guard must stay enabled.

Regression checks use synthetic data, actual AES-GCM encryption, simulated
concurrent writes, and the actual clerk API handler. They cover preservation of
other-device edits, deletion tombstones, account isolation, HTTP 402, clearing
local state, failed decryption, metadata responses and receipt access controls.
Run with `node --test tests/bandwidth-safety.test.cjs`.

## Restore access without buying a plan

First ask Supabase to review the restriction after the traffic fixes are live.
`docs/supabase-support-request.txt` is a draft for the account owner; no support
message has been sent. A courtesy unlock is not guaranteed.

Supabase documents quota refill at the next billing cycle as the normal free
route out of a usage restriction. Confirm the actual next reset in the current
dashboard. An earlier screenshot showed 18 November, but its grace-period text
does not override the restriction now observed on 3 November. Deleting records,
clearing browser caches or creating another project in the same organization
does not refund the accumulated usage.

After access returns, measure daily database/Edge Function egress and query
counts. Budget from measured receipt views and changed vault reads, leaving room
for authentication, retries and other devices. Do not claim that a percentage
reduction in one response guarantees the whole account stays below quota.

## Longer-term database overhaul

Keeping the existing free project is the lowest-change option after access is
restored. For continued growth, replace the single whole-account payload with
encrypted records and download only changes since the last acknowledged server
sequence. A provider move alone would preserve the expensive access pattern.

The intended design has:

- Separate invoices, restaurants/aliases, payments, expenses and draft records,
  retaining immutable IDs and the current owner UUIDs. Encrypt each sensitive
  record rather than weakening the existing confidentiality model.
- A server-assigned change sequence with an ordered change feed. Include deletion
  tombstones so an offline phone cannot reintroduce deleted records. Resetting
  a device cache is never a server deletion command.
- Conditional per-record revisions and transactional invoice/expense changes.
  Conflict resolution is explicit; old data must not silently replace new data.
- A unique owner/source-docket relationship and submission retry keys. Intentional
  additional deliveries need a recorded override; invoice display numbers alone
  are not sufficient for duplicate detection.
- A canonical restaurant ID and explicit aliases, with review for ambiguous
  name matches. Statements and duplicate checks use that same ID.
- Separately stored private receipt attachments, with demand loading and bounded
  sizes. Preserve old receipts during migration and validate every new reference
  before deleting either legacy representation.
- Local durable drafts/outbox in IndexedDB, controlled retry/backoff, visible sync
  outcomes and protected offline exports. Offline recovery must verify the local
  owner's credentials; it must not bypass authentication or access other users.
- A retention policy based on verified backups and storage measurements rather
  than keeping 100 complete account copies for every small edit indefinitely.

A migration must first decrypt an offline copy with the owner's key, compare
invoice IDs/counts, item lines, totals, payment allocations, deleted records,
restaurant references and receipt hashes, then rehearse in an isolated target.
Preserve the original snapshot for rollback. Transfer from a consistent revision,
check totals again, and use a short controlled write pause for cutover. Handle
older phone versions explicitly to avoid two incompatible writers. Do not run
an automatic conversion over the only live copy.

## Alternative free host if Supabase cannot be restored soon

Cloudflare Workers Free + D1 is a candidate after the record design is changed:
100,000 Worker requests/day; 5 million D1 rows read/day; 100,000 rows written/day;
500 MB per free D1 database; 5 GB total across the account. D1 has no egress charge.
These are service limits, not a guarantee of unlimited free production usage.
D1 caps a row/string/blob at 2 MB, so the current receipt design cannot simply be
copied there.

Cloudflare D1 is not a drop-in replacement for Supabase Auth or its Postgres RLS
policies/functions. Moving the database but retaining the restricted Supabase
login would leave sign-in broken. Independent authentication, owner access rules,
invite verification and account recovery must be implemented and reviewed as part
of the move. Preserve legacy user UUIDs for existing encryption-key derivation.

R2 can hold private images and has included free usage with no egress fees, but
requires a subscription checkout and bills usage beyond its allowance. Therefore
it is not offered here as a guaranteed zero-bill solution. Choose an attachment
storage policy and billing controls before adopting it. Hosting on a spare office
PC avoids a cloud subscription only if power, internet, backups and reliable
remote access are already available; those operating costs still exist.

No new paid service, plan upgrade, schema conversion or provider migration is
authorized by this document or performed by the read-only backup script.

## Official references checked 3 November 2026

- Restrictions and dashboard data access: https://supabase.com/kb/troubleshooting/http-status-codes
- Quota resets and restrictions: https://supabase.com/docs/guides/platform/billing-faq
- Egress accounting: https://supabase.com/docs/guides/platform/manage-your-usage/egress
- Backup guidance: https://supabase.com/docs/guides/platform/backups
- D1 pricing: https://developers.cloudflare.com/d1/platform/pricing/
- D1 limits: https://developers.cloudflare.com/d1/platform/limits/
- Workers limits: https://developers.cloudflare.com/workers/platform/limits/
- R2 setup and costs: https://developers.cloudflare.com/r2/get-started/ and https://developers.cloudflare.com/r2/pricing/
