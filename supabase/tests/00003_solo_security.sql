begin;
select no_plan();

insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at)
values
  ('ffffffff-ffff-4fff-8fff-ffffffffffff', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner@example.invalid', '', now()),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'other@example.invalid', '', now());

do $$
begin
  perform set_config('test.known', '{"round_id":"66666666-6666-4666-8666-666666666666","participant_id":"77777777-7777-4777-8777-777777777777","course_id":"11111111-1111-4111-8111-111111111111","layout_version_id":"44444444-4444-4444-8444-444444444444","custom_layout":null}', true);
  perform set_config('test.custom', '{"round_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","participant_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","course_id":"22222222-2222-4222-8222-222222222222","layout_version_id":null,"custom_layout":{"name":"My two-hole practice route","holes":[{"hole_number":1,"par":null,"distance_ft":null},{"hole_number":2,"par":null,"distance_ft":null}]}}', true);
  perform set_config('test.score1', '{"round_id":"66666666-6666-4666-8666-666666666666","participant_id":"77777777-7777-4777-8777-777777777777","hole_number":1,"mutation_id":"99999999-9999-4999-8999-999999999999","expected_revision":0,"strokes":3}', true);
  perform set_config('test.finish', '{"round_id":"66666666-6666-4666-8666-666666666666","mutation_id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","expected_revision":3}', true);
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'ffffffff-ffff-4fff-8fff-ffffffffffff', true);
select is((set_config('test.create_ack', public.create_solo_round_v1(current_setting('test.known')::jsonb)::text, true)::jsonb#>>'{data,id}')::uuid,
  '66666666-6666-4666-8666-666666666666'::uuid, 'owner creates a known-layout round');
select is((select count(*)::integer from public.rounds), 1, 'owner reads own round');
select is(jsonb_array_length(current_setting('test.create_ack')::jsonb#>'{data,holes}'), 3, 'creation acknowledgement contains frozen holes');
select is(jsonb_array_length(current_setting('test.create_ack')::jsonb#>'{data,scores}'), 3, 'creation acknowledgement contains all unplayed cells');
select ok((current_setting('test.create_ack')::jsonb#>'{data,scores}') @> '[{"strokes":null}]'::jsonb, 'creation acknowledgement preserves unplayed null');
select is((select count(*)::integer from public.round_hole_snapshots), 3, 'published holes frozen together with round');
select is((select count(*)::integer from public.hole_scores), 0, 'creation does not invent scores');
select is((select count(*)::integer from public.round_hole_snapshots where par is null and distance_ft is null), 1, 'unknown par and distance frozen as null');
select is((public.create_solo_round_v1(current_setting('test.known')::jsonb)#>>'{data,revision}')::integer, 0, 'round creation retry preserves revision');
select is((select count(*)::integer from public.round_hole_snapshots), 3, 'round creation retry does not duplicate holes');
select is(public.create_solo_round_v1(jsonb_set(current_setting('test.known')::jsonb, '{participant_id}', '"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"'))#>>'{error,code}',
  'IDEMPOTENCY_CONFLICT', 'changed create request is rejected');
select is((public.create_solo_round_v1(current_setting('test.custom')::jsonb)#>>'{data,id}')::uuid,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid, 'owner creates private custom snapshot');
select ok(public.create_solo_round_v1(current_setting('test.custom')::jsonb)#>'{data,layout_version_id}' = 'null'::jsonb,
  'custom creation acknowledgement has no published layout version');
select is((select count(*)::integer from public.round_hole_snapshots where round_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and par is null and distance_ft is null),
  2, 'custom unknown facts remain null');
select is((select count(*)::integer from public.layout_versions), 1, 'custom round did not publish a layout');
select is(public.create_solo_round_v1((jsonb_set(current_setting('test.custom')::jsonb, '{round_id}', '"abababab-abab-4bab-8bab-abababababab"') #- '{custom_layout,holes,0,par}'))#>>'{error,code}',
  'INVALID_REQUEST', 'custom holes require explicit nullable par');
select is(public.write_score_v1(jsonb_set(current_setting('test.score1')::jsonb, '{strokes}', '0'))#>>'{error,code}',
  'INVALID_SCORE', 'zero strokes rejected');
select is(public.write_score_v1(jsonb_set(current_setting('test.score1')::jsonb, '{strokes}', '999999999999999999999999999999'))#>>'{error,code}',
  'INVALID_SCORE', 'oversized strokes return a structured error');
select is(public.write_score_v1(jsonb_set(current_setting('test.score1')::jsonb, '{hole_number}', '4'))#>>'{error,code}',
  'INVALID_REQUEST', 'hole outside snapshot rejected');
select is(public.write_score_v1(jsonb_set(current_setting('test.score1')::jsonb, '{participant_id}', '"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"'))#>>'{error,code}',
  'INVALID_REQUEST', 'participant from another round rejected');
select is(public.complete_round_v1(jsonb_set(current_setting('test.finish')::jsonb, '{expected_revision}', '0'))#>>'{error,code}',
  'INCOMPLETE_ROUND', 'completion with missing scores rejected');
select is((select status from public.rounds where id = '66666666-6666-4666-8666-666666666666'), 'live', 'incomplete round stays live');
select is((set_config('test.score_ack', public.write_score_v1(current_setting('test.score1')::jsonb)::text, true)::jsonb#>>'{data,revision}')::integer,
  1, 'first score write advances revision');
select ok(public.write_score_v1(current_setting('test.score1')::jsonb) = current_setting('test.score_ack')::jsonb,
  'duplicate mutation returns stored acknowledgement');
select is((select revision::integer from public.rounds where id = '66666666-6666-4666-8666-666666666666'), 1, 'replay does not advance revision');
select is((select count(*)::integer from public.hole_scores where round_id = '66666666-6666-4666-8666-666666666666'), 1, 'replay does not duplicate a score');
select ok(public.create_solo_round_v1(current_setting('test.known')::jsonb) = current_setting('test.create_ack')::jsonb,
  'creation replay after scoring returns original acknowledgement');
select is(public.write_score_v1(jsonb_set(current_setting('test.score1')::jsonb, '{strokes}', '4'))#>>'{error,code}',
  'IDEMPOTENCY_CONFLICT', 'mutation UUID cannot be reused with new content');
select is(public.write_score_v1(jsonb_set(jsonb_set(current_setting('test.score1')::jsonb, '{mutation_id}', '"99999999-9999-4999-8999-999999999998"'), '{strokes}', '4'))#>>'{error,code}',
  'STALE_REVISION', 'stale new mutation returns explicit conflict');
select is((public.write_score_v1(jsonb_set(jsonb_set(current_setting('test.score1')::jsonb, '{mutation_id}', '"99999999-9999-4999-8999-999999999998"'), '{strokes}', '4'))#>>'{error,details,current_strokes}')::integer,
  3, 'stale conflict reports the authorized current score');
select is((select revision::integer from public.rounds where id = '66666666-6666-4666-8666-666666666666'), 1, 'stale write leaves revision unchanged');
select is((select strokes from public.hole_scores where round_id = '66666666-6666-4666-8666-666666666666'), 3, 'stale write leaves prior score');
reset role;
select is((select count(*)::integer from internal.mutation_receipts where round_id = '66666666-6666-4666-8666-666666666666'), 1, 'stale mutation creates no receipt');
set local role authenticated;
select is((public.write_score_v1('{"round_id":"66666666-6666-4666-8666-666666666666","participant_id":"77777777-7777-4777-8777-777777777777","hole_number":2,"mutation_id":"99999999-9999-4999-8999-999999999992","expected_revision":1,"strokes":5}')#>>'{data,revision}')::integer,
  2, 'second hole recorded');
select ok(public.complete_round_v1(jsonb_set(current_setting('test.finish')::jsonb, '{expected_revision}', '2'))#>'{error,details,missing_holes}' = '[3]'::jsonb,
  'completion identifies the one remaining unplayed hole');
select is((public.write_score_v1('{"round_id":"66666666-6666-4666-8666-666666666666","participant_id":"77777777-7777-4777-8777-777777777777","hole_number":3,"mutation_id":"99999999-9999-4999-8999-999999999993","expected_revision":2,"strokes":2}')#>>'{data,revision}')::integer,
  3, 'third hole recorded despite unknown par');
select is((set_config('test.finish_ack', public.complete_round_v1(current_setting('test.finish')::jsonb)::text, true)::jsonb#>>'{data,status}'),
  'complete', 'fully scored round completes');
select is((current_setting('test.finish_ack')::jsonb#>>'{data,total_strokes}')::integer, 10, 'completion derives total from recorded strokes');
select ok(current_setting('test.finish_ack')::jsonb#>'{data,vs_par}' = 'null'::jsonb, 'unknown par does not produce relative score');
select ok(public.complete_round_v1(current_setting('test.finish')::jsonb) = current_setting('test.finish_ack')::jsonb,
  'completion replay returns saved acknowledgement');
select is((select revision::integer from public.rounds where id = '66666666-6666-4666-8666-666666666666'), 4, 'completion replay does not advance revision');
select is((public.write_score_v1('{"round_id":"66666666-6666-4666-8666-666666666666","participant_id":"77777777-7777-4777-8777-777777777777","hole_number":2,"mutation_id":"99999999-9999-4999-8999-999999999994","expected_revision":4,"strokes":4}')#>>'{data,revision}')::integer,
  5, 'owner can edit a completed score');
select is((select sum(strokes)::integer from public.hole_scores where round_id = '66666666-6666-4666-8666-666666666666'), 9, 'completed total reflects saved edit');

insert into public.profiles(user_id, handle) values ('ffffffff-ffff-4fff-8fff-ffffffffffff', 'test-owner');
select is((select count(*)::integer from public.profiles), 1, 'owner can bootstrap own profile');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', true);
select is((select count(*)::integer from public.rounds), 0, 'unrelated account cannot read rounds');
select is((select count(*)::integer from public.round_participants), 0, 'unrelated account cannot read participants');
select is((select count(*)::integer from public.round_hole_snapshots), 0, 'unrelated account cannot read snapshots');
select is((select count(*)::integer from public.hole_scores), 0, 'unrelated account cannot read scores');
select is((select count(*)::integer from public.profiles), 0, 'unrelated account cannot read profile');
select is(public.create_solo_round_v1(current_setting('test.known')::jsonb)#>>'{error,code}', 'NOT_FOUND', 'other account cannot replay round creation');
select is(public.write_score_v1(current_setting('test.score1')::jsonb)#>>'{error,code}', 'NOT_FOUND', 'other account cannot edit score');
select is(public.complete_round_v1(current_setting('test.finish')::jsonb)#>>'{error,code}', 'NOT_FOUND', 'other account cannot complete round');
reset role;

set local role anon;
select ok(not has_table_privilege(current_user, 'public.rounds', 'SELECT'), 'anonymous client has no private round read grant');
select ok(not has_function_privilege(current_user, 'public.create_solo_round_v1(jsonb)', 'EXECUTE'), 'anonymous client has no create grant');
select ok(not has_function_privilege(current_user, 'public.write_score_v1(jsonb)', 'EXECUTE'), 'anonymous client has no score grant');
select ok(not has_function_privilege(current_user, 'public.complete_round_v1(jsonb)', 'EXECUTE'), 'anonymous client has no completion grant');
reset role;

select * from finish();
rollback;
