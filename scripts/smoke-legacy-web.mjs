import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const config = Object.fromEntries(execFileSync('./node_modules/.bin/supabase',['status','-o','env'],
  {encoding:'utf8'}).split('\n').map(line => {
  const i=line.indexOf('='); return i<0?[]:[line.slice(0,i),line.slice(i+1).replace(/^"|"$/g,'')];
}).filter(x => x.length));
assert(config.API_URL && config.ANON_KEY);
async function request(path,method='GET',token=config.ANON_KEY,body) {
  const response=await fetch(config.API_URL+path,{method,headers:{apikey:config.ANON_KEY,
    authorization:`Bearer ${token}`,'content-type':'application/json',prefer:'return=representation'},
    body:body===undefined?undefined:JSON.stringify(body)});
  const data=await response.json();
  if(!response.ok) throw new Error(`${path}: ${response.status} ${JSON.stringify(data)}`);
  return data;
}
const email=`birdie-legacy-${Date.now()}@example.test`,password='Birdie-Legacy-2026!';
const account=await request('/auth/v1/signup','POST',undefined,{email,password});
const token=account.access_token;
assert(token && account.user?.id);
globalThis.window={};
const legacy=require('../../birdie_finder_web/assets/legacy-import.js');
const client={rpc:async(name,args)=>{
  try { return {data:await request(`/rest/v1/rpc/${name}`,'POST',token,args),error:null}; }
  catch(error) { return {data:null,error}; }
}};
async function readRound(id) {
  const rows=await request(`/rest/v1/rounds?select=id,revision,status&id=eq.${id}`,'GET',token);
  assert.equal(rows.length,1);
  const holes=await request(`/rest/v1/round_hole_snapshots?select=id,hole_number,par&round_id=eq.${id}&order=hole_number`,'GET',token);
  const scores=await request(`/rest/v1/hole_scores?select=snapshot_hole_id,strokes&round_id=eq.${id}`,'GET',token);
  const byId=new Map(scores.map(s=>[s.snapshot_hole_id,s.strokes]));
  return {...rows[0],holes:holes.map(h=>({...h,strokes:byId.get(h.id)??null}))};
}
window.BFsolo={requireClient:()=>client,requireUser:async()=>({id:account.user.id}),round:readRound};
const raw=readFileSync(new URL('../fixtures/legacy/web-rounds.json',import.meta.url),'utf8');
const deviceId='abababab-1234-4234-8234-abababababab';
const preview=await legacy.previewWebLegacy(raw,deviceId,async slug =>
  slug==='synthetic-pine-loop'?'11111111-1111-4111-8111-111111111111':null);
assert.equal(preview.records.length,3);
assert.equal(preview.records[2].status,'ambiguous');
assert.notEqual(preview.records[0].recordId,preview.records[1].recordId);
for(const record of preview.records.slice(0,2)) {
  assert.equal((await legacy.importWebRecord(record,deviceId)).replayed,false);
  const saved=await readRound(record.roundId);
  assert.equal(saved.status,'complete');
  assert.deepEqual(saved.holes.map(h=>h.strokes),record.scores);
  assert(saved.holes.every(h=>h.par===null));
}
assert.equal((await legacy.importWebRecord(preview.records[0],deviceId)).replayed,true);
const receipts=await request('/rest/v1/rpc/list_legacy_import_receipts_v1','POST',token,{p_device_id:deviceId});
assert.equal(receipts.length,2);
const rounds=await request('/rest/v1/rounds?select=id,started_at&order=id','GET',token);
assert.equal(rounds.length,2);
assert.equal(rounds[0].started_at.slice(0,10),'2026-10-02');
console.log('PASS: two identical-looking web rounds import separately with null par, original date, two receipts, and safe replay');
console.log('PASS: unmatched legacy record stays out of the server and remains exportable from old storage');
