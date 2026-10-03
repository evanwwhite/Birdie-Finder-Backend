# Birdie Finder backend

This repository owns the shared Supabase database migrations, versioned API contract examples, synthetic fixtures, import scripts, and database tests for the website and iPhone app. The app's `supabase/schema.sql` is an earlier draft and is **not** applied by this project. The backend's `supabase/migrations/` directory is the sole migration source.

## How the backend works

This backend is a **Supabase project**, not a separate Node web server. Supabase provides Postgres, account authentication, and an HTTP API for permitted tables and database functions. The website and iPhone app use the same Supabase URL and public anon key for a given environment. After sign-in, Supabase attaches the user's identity to requests; database row level security (RLS) and the round functions decide what that user can read or change. The public key identifies the project and is not an administrator credential.

```text
Approved source -> private staging -> reviewed promotion -> public catalog tables
                                                        -> catalog read functions -> web + app

Supabase Auth -> owner-only round and bag reads -> web + app
              -> transactional round functions -> private rounds and scores
                                                    ^
                                          phone SQLite outbox on reconnect
```

There are two database schemas with different jobs:

| Schema | Purpose | Client access |
| --- | --- | --- |
| `public` | Published courses, layouts, disc molds, profiles, private rounds, scores, and bag items. It also exposes the version-one read and write functions. | Only explicitly granted operations, further limited by RLS. Anonymous users can browse published catalog data; signed-in users can read their own private data. |
| `internal` | Raw catalog imports, source and field reviews, promotion history, and mutation/import receipts. | No direct web or app access. Privileged review and narrowly scoped functions use it. |

### Catalog: from source to screen

1. A source and its permitted fields are recorded in the [source register](docs/SOURCE_REGISTER.md). The import job in `scripts/import/` stages raw course or disc records in `internal`, with provider IDs, hashes, import runs, and field assertions. Staging alone never makes a record visible in either client.
2. A reviewer approves the source, canonical identity match, and individual field values. The promotion function rejects unresolved disagreements and writes approved facts and per-field provenance to the published catalog under a `data_version`. Legacy slugs remain in external-ID crosswalk tables; the clients use canonical UUIDs.
3. Both clients call `search_courses_v1`, `get_course_detail_v1`, or `search_disc_molds_v1` for the public catalog. The search functions currently use `limit` and `offset` pagination. Layout holes preserve nullable par and distance, so an unknown value stays unknown in the UI. The phone caches playable details in SQLite for offline access.

`supabase/seed.sql` contains two synthetic courses for local tests. Public catalog search functions intentionally exclude them. The internal scorecard smoke flow can use those fixtures, but a normal public search needs a reviewed, rights-approved real source before it returns real catalog entries. The current approval state and remaining work are in the [source register](docs/SOURCE_REGISTER.md) and [release runbook](docs/RELEASE_RUNBOOK.md).

### A solo round: from phone or browser to database

1. The client generates UUIDs for the round and owner participant. `create_solo_round_v1` checks the signed-in owner and creates the round, participant, and frozen hole snapshot in one database transaction. It copies a published layout when available; otherwise it accepts a private custom layout confirmed by the player. Later catalog edits cannot rewrite an existing scorecard.
2. The phone first saves each score and its pending operation together in SQLite. On reconnect it sends round creation before score operations. The website sends writes while connected. Both use `write_score_v1` with the round ID, participant ID, hole number, strokes, a unique `mutation_id`, and the `expected_revision`.
3. The score function checks ownership, hole membership, and stroke range, then saves the score and advances the round revision atomically. It stores an acknowledgement in `internal.mutation_receipts`; retrying the *same* mutation returns that acknowledgement without adding another score. A new write based on an old revision returns `STALE_REVISION` so the client can refresh and resolve the edit.
4. `complete_round_v1` succeeds only after every owner hole has a recorded score. No score row means unplayed; the backend never substitutes par. Completed totals come from saved scores, and a relative-to-par result remains unknown if required par values are missing.

For example, a signed-in Supabase client writes a score through the RPC, passing the request as its single `p_request` argument:

```js
const { data, error } = await supabase.rpc('write_score_v1', {
  p_request: {
    round_id: roundId,
    participant_id: participantId,
    hole_number: 1,
    strokes: 3,
    mutation_id: crypto.randomUUID(),
    expected_revision: currentRevision,
  },
});
if (error) throw error; // Transport/database failure.
if (data.error) throw new Error(data.error.code); // Contract-level rejection.
const savedRevision = data.data.revision;
```

The [version-one contract](contracts/v1/README.md) has full request and response examples, null rules, and error codes. Its `/v1/...` paths describe a logical API; the current implementation uses Supabase queries and RPCs, not separate HTTP routes.

### Private data and access rules

- RLS limits round, participant, hole snapshot, score, profile, and bag reads to the owning account. Round writes go through `create_solo_round_v1`, `write_score_v1`, and `complete_round_v1`; unrelated accounts cannot inspect a round to learn its scores or revision.
- The round RPCs use elevated database privileges only to perform a checked transaction. They explicitly check `auth.uid()` and use a fixed empty search path. The catalog read functions use caller permissions. `supabase/tests/` exercises anonymous, owner, and unrelated-account behavior.
- `bag_items` are owner-only rows pointing to published disc molds. Separate web and app legacy importers map old records to canonical IDs, then `ack_legacy_import_v1` records a receipt tied to the account, device, and source record. A retry reuses the receipt. Account export and deletion are exposed through authenticated RPCs.
- Keep the Supabase service-role key and provider credentials out of both clients and Git. A public anon key is suitable for client configuration only because grants, RLS, and RPC ownership checks enforce access.

### Where to make a change

| If you are changing... | Start here |
| --- | --- |
| Tables, policies, or RPC behavior | Add a new ordered file in `supabase/migrations/` and a role/behavior check in `supabase/tests/`. Do not edit an already deployed migration. |
| The client-visible data shape | Update [the contract](contracts/v1/README.md), its JSON examples, and both client adapters. |
| Catalog source or matching rules | Review [source permissions](docs/SOURCE_REGISTER.md), then use `scripts/import/` and the private staging/review flow. |
| Offline score syncing | Inspect the app's `src/state/round.ts` and the round RPCs together; a queued mutation must survive restart and replay with its original ID. |
| Existing user data import | Inspect `fixtures/legacy/`, the web and app importers, and the import receipt RPC. Keep the original local stores until acknowledgement and visibility are confirmed. |

The [data design checklist](../DATA_DESIGN_TODOS.md) tracks acceptance gates. Database and API smoke checks are documented below; device and browser walkthroughs remain separate checks.

## Local development

Requires Node.js 20 or later, npm, and a running Docker-compatible container daemon. The CLI is pinned to version 2.118.0 in `package.json`; use `npm ci` to install the locked version. This project uses only the local Supabase stack and test credentials. Do not link it to a production Supabase project or commit service-role keys.

From this directory:

```sh
npm ci
docker info
npm run start
npm run reset
npm run test:db
```

`npm run reset` recreates the **local** database and reapplies every file in `supabase/migrations/` in order. It destroys local test data. `npm run test:db` runs the SQL tests in `supabase/tests/`. Run `npm run stop` when finished. The CLI prints local API and database connection details after start; use only those local credentials when developing the clients.

## Directories

- `supabase/migrations/`: authoritative, ordered database changes.
- `supabase/tests/`: pgTAP database tests run by `supabase test db`.
- `contracts/v1/`: version-one read and write contract examples (A3).
- `fixtures/`: synthetic catalog, round, and legacy-import examples (A3–A4).
- `scripts/import/`: staged import tooling (C2/C4).

The [version-one contract](contracts/v1/README.md) defines response shapes and Supabase targets. The [legacy fixture notes](fixtures/legacy/README.md) identify the current web and app storage writers. Run `npm run test:fixtures` after changing either set of examples; it parses every JSON file and checks IDs, hole references, score states, replay/conflict behavior, and the separate legacy records.

## Baseline verification

The first migration creates a nonexposed `internal` schema for future staging and import objects. The initial pgTAP test checks that schema exists. Solo-round tables and role tests belong to B1–B2.

Verified on October 2, 2026 with Docker Desktop 29.4.1 and Node.js 26.5.0:

| Command | Result |
| --- | --- |
| `npm ci` | Exit 0; installed the pinned CLI from `package-lock.json`. |
| `docker info --format '{{.ServerVersion}}'` | Exit 0; daemon reported `29.4.1`. |
| `npm run start` | Exit 0; local stack started and applied `20261002000000_create_internal_schema.sql`. |
| `npm run reset` | Exit 0; recreated the local database and reapplied that migration. |
| `npm run test:db` | Exit 0; 1 pgTAP file, 2 assertions, PASS. |

The first start downloaded container images. It also printed local credentials; keep them out of Git and use `supabase status` when you need fresh local values.

Rechecked on October 2, 2026: `docker info --format '{{.ServerVersion}}'` returned `29.4.1`; `npm run start`, `npm run reset`, and `npm run test:db` each exited 0. Reset reapplied the baseline migration; the database test reported 1 file, 2 assertions, PASS. `npm run test:fixtures` exited 0 and validated 21 JSON examples and legacy fixtures. No client repository has a migration directory.

## Solo-round database (B1–B2)

`20261002010000_solo_schema.sql` creates canonical courses/external IDs, published layout versions and holes, profiles, private rounds and participants, frozen round-hole snapshots, scores, and private mutation receipts. `supabase/seed.sql` adds the two **synthetic** courses and known layout from the [version-one examples](contracts/v1/README.md); it is local test data and must not be promoted to a public catalog. The second course has no published layout and requires a private custom snapshot. Unknown par and distance stay null.

`20261002020000_solo_rpc.sql` adds owner-checked transactional RPCs for idempotent creation, score writes, and completion. Client roles have catalog reads and owner-only private reads; private writes go through the RPCs. The RPCs use a fixed empty search path, check `auth.uid()`, save mutation acknowledgements for exact replay, and return an explicit stale-revision conflict. Completed totals are derived from score rows, including edits after completion. The logical `/v1` HTTP paths are contract labels; client integration is B4.

Verified from an empty local database on October 2, 2026:

| Command | Result |
| --- | --- |
| `npm run reset` | Exit 0; applied all three migrations and `supabase/seed.sql`. |
| `npm run test:db` | Exit 0; 3 SQL files, 80 assertions, PASS. Covers seed IDs/nulls, grants, anonymous catalog reads, owner and unrelated-account private reads/writes, incomplete completion, replay, stale revisions, and a completed score edit. |
| `npm run test:fixtures` | Exit 0; 21 JSON fixtures validated. |

## Internal solo client smoke (B3–B5)

The phone's solo round store is `birdie_finder_app/src/state/round.ts`: SQLite commits the round, scores, and outbox mutation together, then replays creation before score and completion RPCs. The browser's `assets/solo.js` uses the same local/test Auth and RPCs. Set the app's ignored `.env` and the web's ignored `assets/config.local.js` to the local API URL and anon key from `supabase status`; use a reachable LAN host for a physical phone. Serve the web folder at `http://127.0.0.1:3000` for the local password reset redirect.

Run the following written scenario after starting the local stack:

1. Create two test accounts through `login.html`; sign into the phone as the first. Start **Synthetic Pine Loop** with the phone offline. Score hole 1, kill and relaunch, and confirm the same score and UUID round resume.
2. Score remaining holes, reconnect, and open the same round on `scorecard.html`. Confirm every stroke appears once and hole 3 par remains unknown. Edit hole 1 on the web, refresh the phone summary, and confirm the edit appears.
3. Repeat the same mutation ID and request; the acknowledgement and revision must be unchanged. Try reading and writing the round as the second account; both must be denied. Create **Synthetic Open Field** and confirm both par values remain null.
4. Request password recovery, open the local Mailpit email, set a new password, and sign in again.

Executed October 3, 2026 against the local stack:

| Command/check | Result |
| --- | --- |
| `npm run start` | Exit 0; local Supabase started. |
| `npm run smoke:solo` | Exit 0; two accounts, profile bootstrap/isolation, create/replay, stale conflict, unrelated-account read/write denial, one saved score after edit, null-par custom round, web Mailpit recovery through new-password sign-in, and the registered app recovery deep link passed. The script uses only local test accounts and does not print credentials. |
| `cd ../birdie_finder_app && npm run typecheck` | Exit 0. |
| `cd ../birdie_finder_app && npx expo export --platform ios --output-dir /tmp/birdie-b3-b5-export` | Exit 0; iOS JavaScript bundle produced. |
| Web script parse checks (commands below) | Exit 0. |
| `xcrun simctl list devices available` | Exit 72: `simctl` unavailable in this workspace. Phone kill/relaunch, browser UI, and phone/web round refresh still require a device or simulator and browser walkthrough. |

The API smoke verifies database behavior, but it does not satisfy the B3–B5 client verification gates by itself. Leave those boxes open until the device and browser steps above pass.

From `birdie_finder_web/`, the exact parse checks were:

```bash
node --check assets/solo.js
node -e "const fs=require('fs');for(const f of ['login.html','scorecard.html','players.html'])for(const m of fs.readFileSync(f,'utf8').matchAll(/<script>([\\s\\S]*?)<\\/script>/g))new Function(m[1]);"
```

## Catalog source review and staging (C1–C2)

The [source register](docs/SOURCE_REGISTER.md) lists current providers, possible fields, permission evidence, attribution, refresh limits, and public-use decisions. No legacy CSV or third-party catalog feed currently has a documented public import grant. The [catalog review](docs/reports/CATALOG_REVIEW.md) compares the existing files without importing them: 330 course hole-count disagreements, 235 coordinate-string disagreements, 774 exact-key disc match candidates, 4 ambiguous app disc rows, and 369 app disc rows without a web match. Its linked CSV files are review queues, not approved crosswalks. Run `npm run review:catalog` to regenerate all reports.

Migration `20261003010000_catalog_staging.sql` keeps import runs, raw record hashes, source records, field assertions, and canonical-ID candidates in the private `internal` schema. Only a privileged reviewer can approve a source, entity match, and individual field. The promotion function requires those reviews and a public-approved source, blocks conflicting non-rejected field values, saves field provenance, and publishes course or disc mold facts under a data version. Staging never publishes. Public roles can read published disc molds but cannot use the private schema or write catalog records.

`node scripts/import/stage_catalog.mjs <batch.json>` stages a JSON batch in the **local** Supabase Docker database. The batch has `source_id` and up to 1,000 `records`; each record has `entity_kind` (`course` or `disc_mold`), `provider_id`, `raw` (the original object), and `fields` (allowed catalog facts). A `proposed_canonical_id` is only a candidate. The job sorts records, computes SHA-256 hashes, and calls the private stage function through local `docker exec`. It requires an enabled source row in `internal.catalog_sources`. Use `npm run stage:catalog:synthetic` for the internal-only fixture; rerunning it must return the same `run_id` and `replayed: true`. The known rights-unresolved sources are blocked in the migration. A privileged reviewer must add permission evidence to the register and approve a source in a new migration before a real feed can be staged; reviewer decisions on matches and assertions must be recorded before promotion. Do not use the synthetic source or a test approval as a public feed.

Verified October 3, 2026 after resetting the local database:

| Command/check | Result |
| --- | --- |
| `npm run reset` | Exit 0; all four migrations and synthetic seed reapplied. |
| `npm run test:db` | Exit 0; 4 SQL files, 114 assertions, PASS. Includes staging access, replay, reviewed course/disc publication in a rolled-back fixture transaction, null preservation, and disputed-value blocking. |
| `npm run stage:catalog:synthetic` twice | Exit 0 both times; three records, same run ID and input hash; second run reported `replayed: true`. Internal staging only. |
| `npm run review:catalog` | Exit 0; regenerated report hashes matched the prior files byte for byte. |
| `npm run smoke:solo`, `npm run test:fixtures`, app `npm run typecheck` | Exit 0; B solo API behavior, 21 fixtures, and phone TypeScript still pass. |
| App `npx expo export --platform ios --output-dir /tmp/birdie-b3-b5-recheck`; web script parse checks above | Exit 0 after the phone refresh correction. The API smoke still cannot exercise device restart or browser UI. |

C1 and C2 remain open until public-use rights and launch coverage are approved, real field and identity conflicts are reviewed, and both clients read the same approved canonical catalog.

## Public-release work in progress (C3–C6)

`20261003020000_catalog_reads.sql` exposes invoker-security course search with nearby sorting and pagination, course/layout detail with nulls and provenance, and disc search. These RPCs exclude the synthetic local seed. Both clients use these canonical reads; the phone caches up to 50 playable details in SQLite for offline access. The app's old prototype routes are archived outside the exported bundle. The web public build uses only allowlisted account/catalog pages; `node ../birdie_finder_web/scripts/build-public.mjs /tmp/birdie-public-web-check` excludes the old CSVs and generated-demo pages. A real approved feed is still needed for a public catalog walkthrough.

`20261003030000_private_imports.sql` adds owner-only `bag_items`, per-account/device/record import receipts, and account export/deletion RPCs. Web and app parsers assign stable record UUIDs and preview unmatched entries before importing. The old device/browser stores remain unchanged. The app requires an explicit owner claim for anonymous rounds and old local stores; another account cannot preview claimed old data. Bag items reference approved canonical disc molds. Matching real legacy records still depends on the C2 reviewed crosswalk; unsupported records remain exportable.

The [release runbook](docs/RELEASE_RUNBOOK.md) records the commercial US pilot, the unapproved CSV rights, hosted-environment steps, rollback/forward recovery, and the local backup drill. No hosted projects exist yet. An isolated local application-schema restore matched source row counts; a raw full restore of Supabase-managed schemas into a blank database failed on a Realtime setting, so the hosted recovery gate remains open.

Latest local verification on October 3, 2026:

| Command/check | Result |
| --- | --- |
| `npm run reset` | Exit 0; all six migrations and local synthetic seed reapplied. |
| `npm run test:db` | Exit 0; 6 SQL files, 151 assertions, PASS. Includes catalog search/detail/paging/nulls, staging conflicts, same-mold bag copies and RLS, duplicate-looking legacy records, historical dates, receipt replay/conflict, export isolation, and owner deletion cascade. |
| `npm run smoke:solo` | Exit 0; two Auth accounts, B round loop, recovery, anonymous catalog exclusion, owner-only export, and one-account deletion passed through local HTTP APIs. |
| `npm run smoke:legacy:web` | Exit 0; two identical-looking browser rounds imported through local HTTP APIs with separate UUIDs, null par, original date, two receipts, and safe replay. |
| `npm run test:legacy` and `npm run test:fixtures` | Web legacy parser kept duplicate-looking records distinct and stable, classified unmatched records, rejected malformed storage; 21 JSON examples validated. |
| App `npm run typecheck`, iOS export, `scripts/check-public-export.mjs` | Exit 0; no legacy course, disc, or hole CSV in exported assets. |
| Web `scripts/build-public.mjs` and `scripts/check-public.mjs` | Exit 0; allowlisted pages, links, script parsing, and exclusions passed. |
| `npm run test:recovery:local` | Exit 0; isolated scoped restore matched catalog, private records, Auth references, and public read counts. |
| `xcrun simctl list devices available` | Exit 72; no simulator utility. Device restart, offline cache, account switching, and cross-client UI still need actual runtime checks. |
