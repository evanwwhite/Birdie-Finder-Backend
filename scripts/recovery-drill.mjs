import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { writeFileSync, readFileSync, unlinkSync } from 'node:fs';
import { randomBytes } from 'node:crypto';

const container='supabase_db_birdie_finder_backend';
const database=`birdie_recovery_${randomBytes(4).toString('hex')}`;
const archive=`/tmp/${database}.dump`;
const docker=(args,options={})=>execFileSync('docker',args,{encoding:'utf8',...options});
let created=false;
try {
  writeFileSync(archive,execFileSync('docker',['exec',container,'pg_dump','-Fc','-U','postgres','-d','postgres'],
    {maxBuffer:50*1024*1024}));
  docker(['exec',container,'createdb','-U','postgres',database]); created=true;
  docker(['exec',container,'psql','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1','-c',
    "CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY); CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS 'SELECT NULL::uuid'; CREATE SCHEMA internal;"]);
  const users=docker(['exec',container,'psql','-U','postgres','-d','postgres','-t','-A','-c',
    'COPY (SELECT id FROM auth.users) TO STDOUT']);
  if (users.trim()) {
    const copy=spawnSync('docker',['exec','-i',container,'psql','-U','postgres','-d',database,
      '-v','ON_ERROR_STOP=1','-c','COPY auth.users(id) FROM STDIN'],{input:users,encoding:'utf8'});
    if (copy.status!==0) throw new Error(copy.stderr || `auth stub copy exited ${copy.status}`);
  }
  const restore=spawnSync('docker',['exec','-i',container,'pg_restore','--no-owner','--no-acl',
    '--exit-on-error','-n','public','-n','internal','-U','postgres','-d',database],
    {input:readFileSync(archive),encoding:'utf8',maxBuffer:20*1024*1024});
  if (restore.status!==0) throw new Error(restore.stderr || `pg_restore exited ${restore.status}`);
  const query="SELECT count(*) FROM public.courses; SELECT count(*) FROM public.layout_holes; SELECT count(*) FROM internal.catalog_sources; SELECT count(*) FROM public.rounds; SELECT count(*) FROM public.hole_scores; SELECT count(*) FROM public.bag_items; SELECT count(*) FROM internal.legacy_import_receipts; SELECT count(*) FROM auth.users; SELECT public.search_courses_v1('',null,null,20,0)->>'total';";
  const counts=db=>docker(['exec',container,'psql','-U','postgres','-d',db,'-t','-A','-c',query]).trim();
  assert.equal(counts(database),counts('postgres'));
  console.log('PASS: scoped local restore matched catalog, private rounds/scores/bags/receipts, Auth references, and public read counts');
} finally {
  if (created) docker(['exec',container,'dropdb','-U','postgres','--if-exists',database]);
  try { unlinkSync(archive); } catch { /* No archive was created. */ }
}
