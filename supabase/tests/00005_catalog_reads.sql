begin;
select no_plan();

select is((public.search_courses_v1('',null,null,20,0)->>'total')::integer,0,
  'public course search excludes synthetic seed');
select is(public.get_course_detail_v1('11111111-1111-4111-8111-111111111111'),null::jsonb,
  'public detail excludes synthetic seed');
select is((public.search_disc_molds_v1('',20,0)->>'total')::integer,0,
  'empty disc catalog has no invented results');

insert into public.courses(id,name,city,state,latitude,longitude,reported_hole_count,
  attribution,data_version,published,synthetic,field_provenance) values
  ('91919191-9191-4191-8191-919191919191','Fixture Public Course','Testville','TS',40,-90,2,
  'Fixture owner','synthetic-2026-10-02-v1',true,false,'{"name":{"source_id":"fixture"}}');
insert into public.layouts(id,course_id,name) values
  ('92929292-9292-4292-8292-929292929292','91919191-9191-4191-8191-919191919191','Main');
insert into public.layout_versions(id,layout_id,version_no,data_version,published) values
  ('93939393-9393-4393-8393-939393939393','92929292-9292-4292-8292-929292929292',1,'synthetic-2026-10-02-v1',true);
insert into public.layout_holes(id,layout_version_id,hole_number,par,distance_ft,par_provenance) values
  ('94949494-9494-4494-8494-949494949491','93939393-9393-4393-8393-939393939393',1,3,null,'{"source_id":"fixture"}'),
  ('94949494-9494-4494-8494-949494949492','93939393-9393-4393-8393-939393939393',2,null,null,null);
insert into public.disc_molds(id,name,manufacturer,data_version,attribution,published) values
  ('95959595-9595-4595-8595-959595959595','Fixture Putter','Fixture Maker','synthetic-2026-10-02-v1','Fixture owner',true);

set local role anon;
select is((public.search_courses_v1('fixture',40,-90,1,0)->>'total')::integer,1,
  'anonymous course search finds approved-style row');
select is((public.search_courses_v1('fixture',40,-90,1,1)->'items')::text,'[]',
  'course search page offset is stable');
select is((public.search_courses_v1('fixture',40,-90,1,0)#>>'{items,0,id}'),
  '91919191-9191-4191-8191-919191919191','course search exposes canonical UUID');
select is((public.get_course_detail_v1('91919191-9191-4191-8191-919191919191')#>>'{layouts,0,versions,0,holes,1,par}'),
  null::text,'unknown par remains null in course detail');
select is((public.get_course_detail_v1('91919191-9191-4191-8191-919191919191')#>>'{field_provenance,name,source_id}'),
  'fixture','course detail carries field provenance');
select is((public.search_disc_molds_v1('putter',20,0)#>>'{items,0,id}'),
  '95959595-9595-4595-8595-959595959595','disc search exposes canonical UUID');
select is((public.search_disc_molds_v1('putter',20,0)#>>'{items,0,speed}'),null::text,
  'unknown disc speed remains null');
reset role;

select * from finish();
rollback;
