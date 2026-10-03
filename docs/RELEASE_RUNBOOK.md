# Staging, recovery, and release runbook

Status on 2026-10-03: **pre-release only**. The owner chose a commercial US pilot but has no hosted staging or production projects yet. Legacy CSV rights are unknown and the minimum verified-course target is pending. No third-party catalog source is approved in [SOURCE_REGISTER.md](SOURCE_REGISTER.md). Do not deploy a public build or copy local test data into a hosted project until the open gates below are satisfied.

## Environment boundaries

1. Create distinct Supabase staging and production projects under an owner-controlled account. Record project refs and contacts in a private operations store, not Git. Set separate Auth redirect allowlists, SMTP settings, database passwords, billing and backup plan, API domains, and monitoring. Apply migrations from this backend repository in numeric order. The app's old `supabase/schema.sql` is not a migration source.
2. Keep service-role/secret keys in server-side deployment secrets only. Web and app builds receive each environment's public URL and **anon/publishable** key. The public web build script rejects `sb_secret_` keys and service-role JWTs. Staging and production must use different keys and projects. Never use a production database dump in local development or staging.
3. Enable only rights-approved catalog sources. A reviewer records the exact approved fields, source terms, attribution, commercial scope, refresh budget, match decisions, and date in the source register and migration. Keep unknown or conflicting facts null/unpublished. Use a controlled backend job for any provider refresh; public clients read only the promoted catalog RPCs.
4. Set the minimum real course and verified layout target before launch. Verify that the public search returns at least that many distinct non-synthetic approved courses in the US pilot region. Synthetic seed rows are for local tests only.

## Build and rollout

1. From an empty **staging** project, apply the migrations and a rights-approved staged catalog. Run SQL role tests, `npm run test:fixtures`, `npm run test:legacy`, app `npm run typecheck`, app iOS export, and `node scripts/build-public.mjs /tmp/birdie-public-staging` with staging's public URL/key set in environment variables. Inspect the output manifest: no legacy CSVs, demo pages, generated reviews, prices, or direct Overpass/DiscIt catalog scripts.
2. Test a real phone and browser against staging. Run the B5 offline restart, score replay, web edit, phone refresh, unrelated-account denial, unknown-par, password recovery, account switch, legacy round import, bag sync, export, and deletion flows. Test an old client against the compatible contract before moving to production. Save the exact devices, builds, commands, and results.
3. Before production migration, confirm a restorable managed backup/point-in-time recovery option and record the restore owner and time objective. Deploy compatible backend changes before clients. Roll out the approved web build and app only with owner release authorization. Monitor Auth, API errors, import failures, and catalog version/attribution. Roll back client routing or advance a corrective migration rather than editing an applied migration.

## Backup and recovery

Use Supabase's managed project backups and documented restore flow for a hosted project; test a **staging** restore to a new isolated project before release. Supabase documents its [database backup options](https://supabase.com/docs/guides/platform/backups) and [restore to a new project](https://supabase.com/docs/guides/platform/clone-project). The latter is a paid-plan beta feature and requires reconfiguration of Auth settings, API keys, Storage objects, and other services. Record the backup timestamp, source and destination project IDs, migration version, source catalog approvals, and restore results. A restore never grants new catalog rights or changes the approved field set.

For a local data-integrity drill only, run `npm run test:recovery:local`. It makes a custom `pg_dump` archive, creates an isolated database with minimal Auth dependencies, restores `public`/`internal`, compares catalog, rounds, scores, bags, receipts, Auth references, and public-read counts, then removes the database and archive. The command passed on October 3, 2026 after the final local migration. Restoring every Supabase-managed schema into a blank database with the ordinary `postgres` role failed on a Realtime function that sets `log_min_messages`; the scoped drill avoids treating that as a production restore procedure. This proves application schema/data integrity locally; it is **not** a hosted Supabase restore validation. [PostgreSQL's `pg_restore` documentation](https://www.postgresql.org/docs/current/app-pgrestore.html) explains custom archives, selective restores, and `--exit-on-error`.

For forward recovery after a bad migration: stop new writes or route users to maintenance, preserve a backup, reproduce the failure in staging, write a new corrective migration (do not edit an applied migration), replay it against a restored staging copy, rerun RLS/client compatibility and catalog checks, then apply it to the affected hosted project with owner authorization. Record the incident and data comparison.

## Open release gates

- Minimum verified real-course coverage target and a rights-cleared feed or written operator submissions for that target.
- Commercial rights/plans for any weather or map service exposed in the public build; keep disabled otherwise.
- Hosted staging and production projects, secure configuration, a tested hosted backup/restore, and rollout monitoring.
- Device/browser B5 and C3–C5 walkthroughs with real approved data, including old-client compatibility.
- Owner authorization for production deployment and client release.
