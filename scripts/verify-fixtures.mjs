import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const examples = join(root, 'contracts/v1/examples');
const legacy = join(root, 'fixtures/legacy');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const read = (dir, file) => JSON.parse(readFileSync(join(dir, file), 'utf8'));
const fixture = (file) => read(examples, `${file}.json`);
const checkUuid = (value) => assert.match(value, uuid);

let fileCount = 0;
for (const dir of [examples, legacy]) {
  for (const file of readdirSync(dir).filter((name) => name.endsWith('.json'))) {
    read(dir, file);
    fileCount++;
  }
}

const page = fixture('courses-page');
const known = fixture('course-known');
const noLayout = fixture('course-no-layout');
const layout = fixture('layout-known');
const crosswalk = fixture('course-external-ids');
const courses = new Map([known.data, noLayout.data].map((course) => [course.id, course]));
assert.equal(page.data_version, known.data_version);
assert.equal(page.data_version, noLayout.data_version);
assert.equal(page.data_version, layout.data_version);
assert.equal(page.data_version, crosswalk.data_version);
assert.deepEqual(new Set(page.data.map((course) => course.id)), new Set(courses.keys()));
assert.deepEqual(page.data.map((course) => course.name), [...page.data.map((course) => course.name)].sort());
assert.equal(page.page.next_cursor, null);
for (const course of courses.values()) checkUuid(course.id);
assert.deepEqual(noLayout.data.published_layout_version_ids, []);
checkUuid(layout.data.layout_id);
checkUuid(layout.data.layout_version_id);
assert.equal(layout.data.course_id, known.data.id);
assert.deepEqual(known.data.published_layout_version_ids, [layout.data.layout_version_id]);
assert.deepEqual(layout.data.holes.map((hole) => hole.hole_number), [1, 2, 3]);
const layoutHoles = new Map(layout.data.holes.map((hole) => [hole.id, hole]));
for (const hole of layout.data.holes) {
  checkUuid(hole.id);
  assert.equal(hole.par === null, hole.par_provenance === null);
  assert.equal(hole.distance_ft === null, hole.distance_provenance === null);
}
for (const mapping of crosswalk.data) {
  checkUuid(mapping.course_id);
  assert.ok(courses.has(mapping.course_id));
  assert.ok(['legacy_web', 'legacy_app'].includes(mapping.provider));
}
assert.equal(new Set(crosswalk.data.map((item) => `${item.provider}:${item.external_id}`)).size, crosswalk.data.length);

const createKnown = fixture('create-known-request');
const createCustom = fixture('create-custom-request');
const created = fixture('create-known-result').data;
const live = fixture('round-live').data;
const complete = fixture('round-complete').data;
const custom = fixture('round-custom').data;
assert.equal(createKnown.course_id, known.data.id);
assert.equal(createKnown.layout_version_id, layout.data.layout_version_id);
assert.equal(createKnown.custom_layout, null);
assert.equal(createCustom.course_id, noLayout.data.id);
assert.equal(createCustom.layout_version_id, null);
assert.deepEqual(createCustom.custom_layout.holes.map((hole) => hole.hole_number), [1, 2]);
assert.ok(createCustom.custom_layout.holes.every((hole) => hole.par === null && hole.distance_ft === null));

function checkRound(round) {
  for (const id of [round.id, round.owner_user_id, round.participant_id, round.course_id]) checkUuid(id);
  assert.ok(courses.has(round.course_id));
  assert.equal(round.data_version, page.data_version);
  assert.deepEqual(round.holes.map((hole) => hole.hole_number), round.holes.map((_, index) => index + 1));
  assert.equal(new Set(round.holes.map((hole) => hole.id)).size, round.holes.length);
  assert.equal(round.scores.length, round.holes.length);
  for (const [index, hole] of round.holes.entries()) {
    checkUuid(hole.id);
    assert.equal(round.scores[index].snapshot_hole_id, hole.id);
    assert.equal(round.scores[index].hole_number, hole.hole_number);
    assert.equal(hole.par === null, hole.par_source === null);
    if (hole.source_layout_hole_id === null) {
      assert.equal(round.layout_version_id, null);
    } else {
      const sourceHole = layoutHoles.get(hole.source_layout_hole_id);
      assert.ok(sourceHole);
      assert.equal(hole.par, sourceHole.par);
      assert.equal(hole.distance_ft, sourceHole.distance_ft);
    }
    const strokes = round.scores[index].strokes;
    assert.ok(strokes === null || (Number.isInteger(strokes) && strokes >= 1 && strokes <= 12));
  }
  const played = round.scores.filter((score) => score.strokes !== null);
  assert.equal(round.played_holes, played.length);
  if (round.status === 'complete') {
    assert.equal(played.length, round.holes.length);
    assert.equal(round.total_strokes, played.reduce((sum, score) => sum + score.strokes, 0));
    assert.ok(round.completed_at);
  } else {
    assert.equal(round.status, 'live');
    assert.equal(round.total_strokes, null);
    assert.equal(round.completed_at, null);
  }
  if (round.holes.some((hole) => hole.par === null)) assert.equal(round.vs_par, null);
}
for (const round of [created, live, complete, custom]) checkRound(round);
assert.equal(created.id, createKnown.round_id);
assert.equal(created.participant_id, createKnown.participant_id);
assert.equal(created.revision, 0);
assert.equal(live.revision, 1);
assert.equal(complete.revision, 4);
assert.equal(custom.id, createCustom.round_id);
assert.equal(custom.participant_id, createCustom.participant_id);
assert.equal(custom.layout_name, createCustom.custom_layout.name);
assert.deepEqual(custom.holes.map((hole) => [hole.par, hole.distance_ft]), createCustom.custom_layout.holes.map((hole) => [hole.par, hole.distance_ft]));

const write = fixture('write-score-request');
const ack = fixture('write-score-result');
assert.deepEqual(fixture('write-score-replay-request'), write);
assert.deepEqual(fixture('write-score-replay-result'), ack);
checkUuid(write.mutation_id);
assert.equal(write.round_id, live.id);
assert.equal(write.participant_id, live.participant_id);
assert.equal(write.expected_revision, created.revision);
assert.equal(ack.data.snapshot_hole_id, live.holes[0].id);
assert.equal(ack.data.strokes, live.scores[0].strokes);
assert.equal(ack.data.revision, live.revision);
assert.equal(ack.data.mutation_id, write.mutation_id);
const stale = fixture('write-score-stale-request');
const conflict = fixture('write-score-stale-result').error;
checkUuid(stale.mutation_id);
assert.notEqual(stale.mutation_id, write.mutation_id);
assert.equal(conflict.code, 'STALE_REVISION');
assert.equal(conflict.details.expected_revision, stale.expected_revision);
assert.equal(conflict.details.current_revision, live.revision);
assert.equal(conflict.details.current_strokes, live.scores[0].strokes);
const finish = fixture('complete-round-request');
checkUuid(finish.mutation_id);
assert.equal(finish.round_id, complete.id);
assert.equal(finish.expected_revision + 1, complete.revision);

const web = read(legacy, 'web-rounds.json');
const app = read(legacy, 'app-rounds.json');
const bag = read(legacy, 'app-bag.json');
assert.ok(Array.isArray(web) && web.length >= 3);
assert.deepEqual(web[0], web[1]);
assert.equal(web[0].date, web[1].date);
assert.deepEqual(web[0].players[0].scores, web[1].players[0].scores);
assert.equal('courseId' in web[2], false);
assert.equal(app.version, 0);
assert.ok(app.state.live && Array.isArray(app.state.history));
assert.equal('holes' in app.state.live, false);
assert.equal(app.state.live.scores.player01['2'], undefined);
assert.notEqual(app.state.history[0].id, app.state.history[1].id);
assert.equal(app.state.history[0].playedAt, app.state.history[1].playedAt);
assert.deepEqual(app.state.history[0].scores, app.state.history[1].scores);
assert.equal('pars' in app.state.history[2], false);
assert.equal(bag.version, 0);
assert.equal(bag.state.seeded, true);
assert.ok(Array.isArray(bag.state.discs));
assert.equal('pic' in bag.state.discs[0], false);

console.log(`Validated ${fileCount} JSON fixtures, canonical references, round states, replay/conflict, and distinct legacy records.`);
