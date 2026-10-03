import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';

const lines = execFileSync('./node_modules/.bin/supabase', ['status', '-o', 'env'], { encoding: 'utf8' });
const config = Object.fromEntries(lines.split('\n').map(line => {
  const index = line.indexOf('=');
  return index < 0 ? [] : [line.slice(0, index), line.slice(index + 1).replace(/^"|"$/g, '')];
}).filter(pair => pair.length));
const base = config.API_URL;
const anon = config.ANON_KEY;
assert(base && anon, 'Local Supabase API and anon key are required');

async function request(path, method = 'GET', token, body) {
  const response = await fetch(base + path, { method, headers: {
    apikey: anon, authorization: `Bearer ${token || anon}`,
    'content-type': 'application/json', prefer: 'return=representation',
  }, body: body === undefined ? undefined : JSON.stringify(body) });
  const data = await response.json();
  if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${JSON.stringify(data)}`);
  return data;
}
const rpc = (token, name, body) => request(`/rest/v1/rpc/${name}`, 'POST', token, { p_request: body });
const stamp = Date.now();
const password = 'Birdie-Test-2026!';
async function signup(label) {
  const email = `birdie-smoke-${label}-${stamp}@example.test`;
  const data = await request('/auth/v1/signup', 'POST', null, { email, password });
  const token = data.access_token || (await request('/auth/v1/token?grant_type=password', 'POST', null, { email, password })).access_token;
  assert(token, `No session for ${label}`);
  return { email, token, id: data.user?.id };
}
const a = await signup('a');
const b = await signup('b');
console.log('PASS: two accounts created and signed in');
const profile = await request('/rest/v1/profiles', 'POST', a.token, { user_id: a.id });
assert.equal(profile[0].user_id, a.id);
assert.equal((await request('/rest/v1/profiles?select=user_id', 'GET', b.token)).length, 0);
console.log('PASS: owner profile bootstrap and isolation');

const known = { round_id: crypto.randomUUID(), participant_id: crypto.randomUUID(),
  course_id: '11111111-1111-4111-8111-111111111111',
  layout_version_id: '44444444-4444-4444-8444-444444444444', custom_layout: null };
const created = await rpc(a.token, 'create_solo_round_v1', known);
assert.equal(created.data.id, known.round_id);
assert.equal(created.data.holes[2].par, null);
const replay = await rpc(a.token, 'create_solo_round_v1', known);
assert.deepEqual(replay, created);
console.log('PASS: known-layout round and idempotent create');

const score = { round_id: known.round_id, participant_id: known.participant_id,
  mutation_id: crypto.randomUUID(), hole_number: 1, strokes: 3, expected_revision: 0 };
const first = await rpc(a.token, 'write_score_v1', score);
assert.equal(first.data.revision, 1);
assert.deepEqual(await rpc(a.token, 'write_score_v1', score), first);
const stale = await rpc(a.token, 'write_score_v1', { ...score, mutation_id: crypto.randomUUID(), strokes: 4 });
assert.equal(stale.error.code, 'STALE_REVISION');
const foreign = await rpc(b.token, 'write_score_v1', { ...score, mutation_id: crypto.randomUUID(), expected_revision: 1 });
assert.equal(foreign.error.code, 'NOT_FOUND');
const invisible = await request(`/rest/v1/rounds?select=id&id=eq.${known.round_id}`, 'GET', b.token);
assert.equal(invisible.length, 0);
console.log('PASS: mutation replay, stale revision, unrelated-account edit/read denied');

const webEdit = await rpc(a.token, 'write_score_v1', { ...score, mutation_id: crypto.randomUUID(), strokes: 4, expected_revision: 1 });
assert.equal(webEdit.data.revision, 2);
const saved = await request(`/rest/v1/hole_scores?select=strokes&round_id=eq.${known.round_id}`, 'GET', a.token);
assert.equal(saved.length, 1);
assert.equal(saved[0].strokes, 4);
const custom = { round_id: crypto.randomUUID(), participant_id: crypto.randomUUID(),
  course_id: '22222222-2222-4222-8222-222222222222', layout_version_id: null,
  custom_layout: { name: 'Private custom layout', holes: [1, 2].map(hole_number => ({ hole_number, par: null, distance_ft: null })) } };
const unknown = await rpc(a.token, 'create_solo_round_v1', custom);
assert.equal(unknown.data.holes.length, 2);
assert(unknown.data.holes.every(hole => hole.par === null));
console.log('PASS: one saved score after edit and custom round with unknown par');

const webRedirect = 'http://127.0.0.1:3000/login.html';
await request(`/auth/v1/recover?redirect_to=${encodeURIComponent(webRedirect)}`, 'POST', null, { email: a.email });
const mail = await fetch('http://127.0.0.1:54324/api/v1/messages').then(response => response.json());
const recoveryMail = mail.messages?.find(message => message.To?.some(to => to.Address === a.email));
assert(recoveryMail, 'Recovery email not found in local Mailpit');
const detail = await fetch(`http://127.0.0.1:54324/api/v1/message/${recoveryMail.ID}`).then(response => response.json());
const recoveryUrl = detail.Text.match(/https?:\/\/[^\s<>]+\/auth\/v1\/verify\?[^\s<>]+/)?.[0];
assert(recoveryUrl, 'Recovery link missing');
assert.equal(new URL(recoveryUrl).searchParams.get('redirect_to'), webRedirect);
const verify = await fetch(recoveryUrl, { redirect: 'manual' });
const location = verify.headers.get('location');
assert(location, 'Recovery redirect missing');
const accessToken = new URLSearchParams(new URL(location).hash.slice(1)).get('access_token');
assert(accessToken, 'Recovery session missing');
const changedPassword = 'Birdie-Reset-2026!';
await request('/auth/v1/user', 'PUT', accessToken, { password: changedPassword });
const recovered = await request('/auth/v1/token?grant_type=password', 'POST', null, { email: a.email, password: changedPassword });
assert(recovered.access_token, 'Could not sign in with recovered password');
console.log('PASS: password recovery email, password update, and sign-in');
const appRedirect = 'birdiefinder://login';
await request(`/auth/v1/recover?redirect_to=${encodeURIComponent(appRedirect)}`, 'POST', null, { email: b.email });
const appMail = await fetch('http://127.0.0.1:54324/api/v1/messages').then(response => response.json());
const appMessage = appMail.messages.find(message => message.To?.some(to => to.Address === b.email));
assert(appMessage, 'App recovery email not found');
const appDetail = await fetch(`http://127.0.0.1:54324/api/v1/message/${appMessage.ID}`).then(response => response.json());
const appUrl = appDetail.Text.match(/https?:\/\/[^\s<>]+\/auth\/v1\/verify\?[^\s<>]+/)?.[0];
assert.equal(new URL(appUrl).searchParams.get('redirect_to'), appRedirect);
console.log('PASS: app recovery link uses registered deep link');
const publicCourses = await request('/rest/v1/rpc/search_courses_v1', 'POST', null,
  { p_query: '', p_lat: null, p_lon: null, p_limit: 20, p_offset: 0 });
assert.equal(publicCourses.total, 0);
const publicDiscs = await request('/rest/v1/rpc/search_disc_molds_v1', 'POST', null,
  { p_query: '', p_limit: 20, p_offset: 0 });
assert.equal(publicDiscs.total, 0);
console.log('PASS: anonymous public catalog hides internal seed and has no invented disc molds');
const exportA = await request('/rest/v1/rpc/export_account_v1', 'POST', recovered.access_token, {});
const exportB = await request('/rest/v1/rpc/export_account_v1', 'POST', b.token, {});
assert.equal(exportA.user_id, a.id);
assert.equal(exportA.rounds.length, 2);
assert.equal(exportB.user_id, b.id);
assert.equal(exportB.rounds.length, 0);
console.log('PASS: account export contains only owner rounds');
const deleted = await request('/rest/v1/rpc/delete_account_v1', 'POST', b.token,
  { p_confirmation: 'DELETE MY BIRDIE FINDER ACCOUNT' });
assert.equal(deleted.deleted, true);
assert.equal((await request('/rest/v1/rounds?select=id', 'GET', recovered.access_token)).length, 2);
console.log('PASS: deletion removes one test account and leaves the other account intact');
console.log('Local API smoke passed. Phone restart and cross-client UI steps require a device/browser runtime.');
