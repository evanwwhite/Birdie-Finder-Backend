#!/usr/bin/env node
// Stage a rights-approved source in the local private schema. Never publishes.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const inputPath = process.argv[2];
if (!inputPath) throw new Error('Usage: node scripts/import/stage_catalog.mjs <approved-batch.json>');
const input = JSON.parse(readFileSync(resolve(inputPath), 'utf8'));
if (!/^[a-z][a-z0-9_]*$/.test(input.source_id) || !Array.isArray(input.records) || input.records.length > 1000) {
  throw new Error('Invalid source or record batch');
}
const canonical = value => Array.isArray(value) ? value.map(canonical)
  : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]))
    : value;
const hash = value => createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
const seen = new Set();
const records = input.records.map(record => {
  if (!['course', 'disc_mold'].includes(record.entity_kind) ||
      typeof record.provider_id !== 'string' || !record.provider_id.trim() ||
      !record.raw || typeof record.raw !== 'object' || Array.isArray(record.raw) ||
      !record.fields || typeof record.fields !== 'object' || Array.isArray(record.fields)) {
    throw new Error('Each record needs entity_kind, provider_id, raw, and fields');
  }
  const key = `${record.entity_kind}:${record.provider_id}`;
  if (seen.has(key)) throw new Error(`Duplicate provider record in batch: ${key}`);
  seen.add(key);
  return { ...record, raw_sha256: hash(record.raw) };
}).sort((a, b) => `${a.entity_kind}:${a.provider_id}`.localeCompare(`${b.entity_kind}:${b.provider_id}`));
const inputSha = hash(records);
const project = readFileSync(new URL('../../supabase/config.toml', import.meta.url), 'utf8')
  .match(/^project_id\s*=\s*"([a-zA-Z0-9_-]+)"/m)?.[1];
if (!project) throw new Error('Missing local Supabase project ID');
const tag = `catalog_${randomUUID().replaceAll('-', '')}`;
const payload = JSON.stringify(records);
if (payload.includes(`$${tag}$`)) throw new Error('Unexpected SQL delimiter collision');
const sql = `select internal.stage_catalog_batch_v1('${input.source_id}', '${randomUUID()}', '${inputSha}', $${tag}$${payload}$${tag}$::jsonb)::text;\n`;
const result = spawnSync('docker', ['exec', '-i', `supabase_db_${project}`, 'psql', '-X', '-q', '-t', '-A',
  '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'], { input: sql, encoding: 'utf8' });
if (result.error) throw result.error;
if (result.status !== 0) throw new Error(result.stderr.trim() || `psql exit ${result.status}`);
const response = JSON.parse(result.stdout.trim());
console.log(JSON.stringify({ source_id: input.source_id, input_sha256: inputSha, ...response }));
