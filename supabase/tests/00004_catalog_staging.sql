begin;
select no_plan();

select is((select approval_status from internal.catalog_sources where source_id='internal_synthetic'),
  'internal_only', 'synthetic source is restricted to internal staging');
select ok(not has_schema_privilege('authenticated', 'internal', 'USAGE'), 'client cannot use staging schema');
select ok(not has_table_privilege('authenticated', 'public.disc_molds', 'INSERT'), 'client cannot publish disc molds');

select is((internal.stage_catalog_batch_v1('internal_synthetic',
  '10101010-1010-4010-8010-101010101010', repeat('a',64), jsonb_build_array(
    jsonb_build_object('entity_kind','course','provider_id','test-pine',
      'proposed_canonical_id','11111111-1111-4111-8111-111111111111',
      'raw_sha256',repeat('1',64),'raw',jsonb_build_object('name','Synthetic Pine Loop'),
      'fields',jsonb_build_object('name','Synthetic Pine Loop','reported_hole_count',3))))#>>'{replayed}')::boolean,
  false, 'first synthetic batch stages privately');
select is((select count(*)::integer from internal.catalog_import_runs where input_sha256=repeat('a',64)), 1, 'one import run recorded');
select is((select count(*)::integer from internal.catalog_source_records where provider_id='test-pine'), 1, 'one raw record retained');
select is((select count(*)::integer from internal.catalog_field_assertions a
  join internal.catalog_source_records r on r.id=a.source_record_id where r.provider_id='test-pine'), 2, 'each staged field has an assertion');
select is((select count(*)::integer from internal.catalog_field_assertions a
  join internal.catalog_source_records r on r.id=a.source_record_id where r.provider_id='test-pine' and a.review_status='pending'), 2,
  'staging never approves assertions');
select is((select review_status from internal.catalog_entity_matches where provider_id='test-pine'),
  'candidate', 'canonical match remains a candidate');
select is((internal.stage_catalog_batch_v1('internal_synthetic',
  '20202020-2020-4020-8020-202020202020', repeat('a',64), '[]'::jsonb)#>>'{replayed}')::boolean,
  true, 'same input hash replays the original run');
select is((select count(*)::integer from internal.catalog_import_runs where input_sha256=repeat('a',64)), 1, 'replay does not add a run');

do $$
begin
  perform internal.stage_catalog_batch_v1('legacy_web',
    '30303030-3030-4030-8030-303030303030', repeat('b',64), '[]'::jsonb);
exception when others then perform set_config('test.unapproved_stage_error', SQLERRM, true);
end;
$$;
select ok(current_setting('test.unapproved_stage_error') like 'SOURCE_NOT_APPROVED_FOR_STAGING%',
  'unknown legacy source cannot be staged');
do $$
begin
  perform internal.promote_catalog_entity_v1('course',
    '11111111-1111-4111-8111-111111111111', 'test-public-v1', 'fixture-reviewer');
exception when others then perform set_config('test.synthetic_promotion_error', SQLERRM, true);
end;
$$;
select is(current_setting('test.synthetic_promotion_error'), 'NO_APPROVED_FIELDS',
  'internal-only assertions cannot be promoted');

select is((internal.stage_catalog_batch_v1('internal_synthetic',
  '40404040-4040-4040-8040-404040404040', repeat('c',64), jsonb_build_array(
    jsonb_build_object('entity_kind','course','provider_id','test-pine',
      'proposed_canonical_id','11111111-1111-4111-8111-111111111111',
      'raw_sha256',repeat('2',64),'raw',jsonb_build_object('name','Synthetic Pine Loop revised'),
      'fields',jsonb_build_object('name','Synthetic Pine Loop revised'))))#>>'{replayed}')::boolean,
  false, 'changed raw record creates another run');
select is((select count(*)::integer from internal.catalog_source_records where provider_id='test-pine' and is_latest),
  1, 'only one version is latest');
select is((select count(*)::integer from internal.catalog_source_records where provider_id='test-pine'),
  2, 'old raw record remains in audit history');
select is((select name from public.courses where id='11111111-1111-4111-8111-111111111111'),
  'Synthetic Pine Loop', 'private changed record did not alter public seed');

-- A rights-approved operator in this rollback-only test proves the promotion gate.
insert into internal.catalog_sources(source_id,approval_status,evidence_url,attribution,refresh_rule,approved_by,approved_at)
values ('test_operator','public_approved','fixture://rights-check','Fixture operator','manual','test-reviewer',now());
select is((internal.stage_catalog_batch_v1('test_operator',
  '50505050-5050-4050-8050-505050505050', repeat('d',64), jsonb_build_array(
    jsonb_build_object('entity_kind','course','provider_id','owner-course-1',
      'proposed_canonical_id','90909090-9090-4090-8090-909090909090',
      'raw_sha256',repeat('3',64),'raw',jsonb_build_object('name','Fixture Course'),
      'fields',jsonb_build_object('name','Fixture Course','city','Testville','state','TS',
        'reported_hole_count',null))))#>>'{record_count}')::integer,
  1, 'approved test source can stage a course');
update internal.catalog_entity_matches set review_status='approved',reviewed_by='test-reviewer',reviewed_at=now()
  where source_id='test_operator' and provider_id='owner-course-1';
update internal.catalog_field_assertions set review_status='approved',reviewed_by='test-reviewer',reviewed_at=now()
  where source_record_id in (select id from internal.catalog_source_records where source_id='test_operator');
select is((internal.promote_catalog_entity_v1('course','90909090-9090-4090-8090-909090909090',
  'test-approved-v1','test-reviewer')#>>'{replayed}')::boolean,
  false, 'reviewed rights-approved fields promote');
select is((select name from public.courses where id='90909090-9090-4090-8090-909090909090'),
  'Fixture Course', 'published course uses reviewed name');
select ok((select latitude is null and longitude is null and reported_hole_count is null from public.courses
  where id='90909090-9090-4090-8090-909090909090'), 'unknown course fields remain null');
select is((select field_provenance#>>'{name,source_id}' from public.courses
  where id='90909090-9090-4090-8090-909090909090'),
  'test_operator', 'published name retains field provenance');
select is((select course_id from public.course_external_ids where provider='test_operator' and external_id='owner-course-1'),
  '90909090-9090-4090-8090-909090909090'::uuid, 'external ID maps to reviewed canonical UUID');
select is((internal.promote_catalog_entity_v1('course','90909090-9090-4090-8090-909090909090',
  'test-approved-v1','test-reviewer')#>>'{replayed}')::boolean,
  true, 'same promotion is idempotent');

select is((internal.stage_catalog_batch_v1('test_operator',
  '60606060-6060-4060-8060-606060606060', repeat('e',64), jsonb_build_array(
    jsonb_build_object('entity_kind','course','provider_id','owner-course-2',
      'proposed_canonical_id','90909090-9090-4090-8090-909090909090',
      'raw_sha256',repeat('4',64),'raw',jsonb_build_object('name','Disputed Course'),
      'fields',jsonb_build_object('name','Disputed Course'))))#>>'{record_count}')::integer,
  1, 'second source record stages a disputed value');
update internal.catalog_entity_matches set review_status='approved',reviewed_by='test-reviewer',reviewed_at=now()
  where source_id='test_operator' and provider_id='owner-course-2';
do $$
begin
  perform internal.promote_catalog_entity_v1('course',
    '90909090-9090-4090-8090-909090909090', 'test-approved-v2', 'test-reviewer');
exception when others then perform set_config('test.disputed_promotion_error', SQLERRM, true);
end;
$$;
select is(current_setting('test.disputed_promotion_error'), 'UNRESOLVED_FIELD_CONFLICT',
  'a pending disagreement blocks a new public version');
select is((select count(*)::integer from internal.catalog_promotions where data_version='test-approved-v2'),
  0, 'disputed values remain unpublished');

select is((internal.stage_catalog_batch_v1('test_operator',
  '70707070-7070-4070-8070-707070707070', repeat('f',64), jsonb_build_array(
    jsonb_build_object('entity_kind','disc_mold','provider_id','owner-disc-1',
      'proposed_canonical_id','80808080-8080-4080-8080-808080808080',
      'raw_sha256',repeat('5',64),'raw',jsonb_build_object('name','Fixture Driver'),
      'fields',jsonb_build_object('name','Fixture Driver','manufacturer','Fixture Maker',
        'speed',null))))#>>'{record_count}')::integer,
  1, 'disc mold stages without inventing flight values');
update internal.catalog_entity_matches set review_status='approved',reviewed_by='test-reviewer',reviewed_at=now()
  where source_id='test_operator' and provider_id='owner-disc-1';
update internal.catalog_field_assertions set review_status='approved',reviewed_by='test-reviewer',reviewed_at=now()
  where source_record_id in (select id from internal.catalog_source_records
    where source_id='test_operator' and entity_kind='disc_mold');
select is((internal.promote_catalog_entity_v1('disc_mold','80808080-8080-4080-8080-808080808080',
  'test-disc-v1','test-reviewer')#>>'{replayed}')::boolean,
  false, 'reviewed disc mold promotes');
select ok((select name='Fixture Driver' and speed is null and glide is null
  from public.disc_molds where id='80808080-8080-4080-8080-808080808080'),
  'disc keeps unknown flight values null');
select is((select disc_mold_id from public.disc_external_ids
  where provider='test_operator' and external_id='owner-disc-1'),
  '80808080-8080-4080-8080-808080808080'::uuid, 'disc provider ID maps to canonical UUID');

set local role anon;
select is((select count(*)::integer from public.courses where id='90909090-9090-4090-8090-909090909090'),
  1, 'anonymous catalog read sees published approved course');
select is((select count(*)::integer from public.disc_molds), 1, 'only reviewed disc is visible');
select ok(not has_schema_privilege(current_user,'internal','USAGE'), 'anonymous role cannot read staging');
reset role;

select * from finish();
rollback;
