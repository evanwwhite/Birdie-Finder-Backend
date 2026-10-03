begin;
select no_plan();

select is((select count(*)::integer from public.courses), 2, 'exactly two synthetic courses are seeded');
select is((select count(*)::integer from public.courses where synthetic and published), 2, 'both seed courses are marked synthetic and published locally');
select is((select count(*)::integer from public.course_external_ids), 4, 'both legacy namespaces map both courses');
select ok((select array_agg(id order by id) from public.courses) = array[
  '11111111-1111-4111-8111-111111111111'::uuid,
  '22222222-2222-4222-8222-222222222222'::uuid], 'course UUIDs match A3 fixtures');
select is((select course_id from public.course_external_ids where provider = 'legacy_web' and external_id = 'synthetic-open-field'),
  '22222222-2222-4222-8222-222222222222'::uuid, 'legacy slug maps to course without layout');
select is((select count(*)::integer from public.layout_versions where published), 1, 'only the known course has a published version');
select is((select layout_id from public.layout_versions where id = '44444444-4444-4444-8444-444444444444'),
  '33333333-3333-4333-8333-333333333333'::uuid, 'known layout UUIDs match A3 fixtures');
select is((select count(*)::integer from public.layout_holes), 3, 'known layout has three holes');
select ok((select jsonb_agg(jsonb_build_object('id', id, 'hole_number', hole_number, 'par', par, 'distance_ft', distance_ft) order by hole_number)
  from public.layout_holes where layout_version_id = '44444444-4444-4444-8444-444444444444') =
  '[{"id":"55555555-5555-4555-8555-555555555551","hole_number":1,"par":3,"distance_ft":250},{"id":"55555555-5555-4555-8555-555555555552","hole_number":2,"par":4,"distance_ft":null},{"id":"55555555-5555-4555-8555-555555555553","hole_number":3,"par":null,"distance_ft":null}]'::jsonb,
  'hole UUIDs, order, par, and distance match A3 fixture');
select is((select count(*)::integer from public.layout_holes where par is null and distance_ft is null), 1, 'unknown par and distance remain null');
select is((select count(*)::integer from public.layout_holes where par is not null and distance_ft is null), 1, 'distance can be unknown independently of par');
select is((select count(*)::integer from public.layout_versions v join public.layouts l on l.id = v.layout_id where l.course_id = '22222222-2222-4222-8222-222222222222'), 0, 'course without a verified layout has no generated version');
select is((select data_version from public.courses where id = '11111111-1111-4111-8111-111111111111'), 'synthetic-2026-10-02-v1', 'catalog version matches contract fixture');
select ok((select not has_schema_privilege('anon', 'internal', 'USAGE')), 'internal schema is not exposed to anonymous clients');
select ok((select not has_table_privilege('authenticated', 'public.courses', 'INSERT')), 'clients cannot write catalog rows');
select ok((select not has_table_privilege('authenticated', 'public.rounds', 'INSERT')), 'clients cannot bypass round creation RPC');
select ok((select not has_table_privilege('authenticated', 'public.hole_scores', 'UPDATE')), 'clients cannot bypass score RPC');
select ok((select not has_function_privilege('anon', 'public.create_solo_round_v1(jsonb)', 'EXECUTE')), 'anonymous client has no create RPC grant');
select ok((select not has_function_privilege('anon', 'public.write_score_v1(jsonb)', 'EXECUTE')), 'anonymous client has no score RPC grant');
select ok((select not has_function_privilege('anon', 'public.complete_round_v1(jsonb)', 'EXECUTE')), 'anonymous client has no completion RPC grant');

set local role anon;
select is((select count(*)::integer from public.courses), 2, 'anonymous catalog browse sees both synthetic courses locally');
select is((select count(*)::integer from public.layout_holes), 3, 'anonymous catalog browse sees published holes');
reset role;

select * from finish();
rollback;
