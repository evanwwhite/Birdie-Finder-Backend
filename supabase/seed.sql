-- Synthetic development fixtures. Never promote these rows to a public catalog.
insert into public.catalog_versions(data_version) values ('synthetic-2026-10-02-v1');
insert into public.courses(id, name, city, state, reported_hole_count, reported_hole_count_provenance, data_version, published, synthetic) values
  ('11111111-1111-4111-8111-111111111111', 'Synthetic Pine Loop', 'Testville', 'TS', 3, '{"source_type":"synthetic_fixture","verification":"synthetic"}', 'synthetic-2026-10-02-v1', true, true),
  ('22222222-2222-4222-8222-222222222222', 'Synthetic Open Field', 'Testville', 'TS', 2, '{"source_type":"synthetic_fixture","verification":"synthetic"}', 'synthetic-2026-10-02-v1', true, true);
insert into public.course_external_ids(provider, external_id, course_id) values
  ('legacy_web', 'synthetic-pine-loop', '11111111-1111-4111-8111-111111111111'),
  ('legacy_app', 'synthetic-pine-loop', '11111111-1111-4111-8111-111111111111'),
  ('legacy_web', 'synthetic-open-field', '22222222-2222-4222-8222-222222222222'),
  ('legacy_app', 'synthetic-open-field', '22222222-2222-4222-8222-222222222222');
insert into public.layouts(id, course_id, name) values
  ('33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111', 'Test Route');
insert into public.layout_versions(id, layout_id, version_no, data_version, published) values
  ('44444444-4444-4444-8444-444444444444', '33333333-3333-4333-8333-333333333333', 1, 'synthetic-2026-10-02-v1', true);
insert into public.layout_holes(id, layout_version_id, hole_number, par, distance_ft, par_provenance, distance_provenance) values
  ('55555555-5555-4555-8555-555555555551', '44444444-4444-4444-8444-444444444444', 1, 3, 250, '{"source_type":"synthetic_fixture","verification":"synthetic"}', '{"source_type":"synthetic_fixture","verification":"synthetic"}'),
  ('55555555-5555-4555-8555-555555555552', '44444444-4444-4444-8444-444444444444', 2, 4, null, '{"source_type":"synthetic_fixture","verification":"synthetic"}', null),
  ('55555555-5555-4555-8555-555555555553', '44444444-4444-4444-8444-444444444444', 3, null, null, null, null);
