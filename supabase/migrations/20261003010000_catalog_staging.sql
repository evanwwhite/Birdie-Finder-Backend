-- Private catalog staging. No client role can inspect or write these records.
create table internal.catalog_sources (
  source_id text primary key,
  approval_status text not null check (approval_status in ('blocked', 'internal_only', 'public_approved')),
  evidence_url text,
  attribution text,
  refresh_rule text,
  approved_by text,
  approved_at timestamptz,
  check (approval_status <> 'public_approved' or
    (nullif(btrim(evidence_url), '') is not null and nullif(btrim(attribution), '') is not null and
     nullif(btrim(approved_by), '') is not null and approved_at is not null))
);
insert into internal.catalog_sources(source_id, approval_status, evidence_url, attribution, refresh_rule)
values ('internal_synthetic', 'internal_only', 'supabase/seed.sql', 'Synthetic fixture — internal testing only', 'local reset only');
insert into internal.catalog_sources(source_id, approval_status, evidence_url, attribution, refresh_rule) values
  ('legacy_web_courses','blocked','docs/SOURCE_REGISTER.md',null,'unknown'),
  ('legacy_app_courses','blocked','docs/SOURCE_REGISTER.md',null,'unknown'),
  ('legacy_web_discs','blocked','docs/SOURCE_REGISTER.md',null,'unknown'),
  ('legacy_app_discs','blocked','docs/SOURCE_REGISTER.md',null,'unknown'),
  ('discgolfapi','blocked','https://discgolfapi.com/licence/','Course data supplied by DiscGolfAPI.','cache; no full mirror'),
  ('osm','blocked','https://www.openstreetmap.org/copyright','© OpenStreetMap contributors','controlled extract only'),
  ('discit','blocked','https://github.com/DiscIt-API/discit-api',null,'nightly upstream; rights unresolved'),
  ('pdga','blocked','https://www.pdga.com/tos',null,'no automated copying'),
  ('operator_submission','blocked','docs/SOURCE_REGISTER.md',null,'per agreement');

create table internal.catalog_import_runs (
  id uuid primary key,
  source_id text not null references internal.catalog_sources(source_id),
  input_sha256 text not null check (input_sha256 ~ '^[0-9a-f]{64}$'),
  record_count integer not null check (record_count >= 0),
  imported_at timestamptz not null default now(),
  unique (source_id, input_sha256)
);

create table internal.catalog_source_records (
  id uuid primary key default gen_random_uuid(),
  source_id text not null references internal.catalog_sources(source_id),
  entity_kind text not null check (entity_kind in ('course', 'disc_mold')),
  provider_id text not null check (length(btrim(provider_id)) > 0),
  raw_sha256 text not null check (raw_sha256 ~ '^[0-9a-f]{64}$'),
  raw_record jsonb not null check (jsonb_typeof(raw_record) = 'object'),
  observed_at timestamptz,
  first_run_id uuid not null references internal.catalog_import_runs(id),
  last_run_id uuid not null references internal.catalog_import_runs(id),
  is_latest boolean not null default true,
  unique (source_id, entity_kind, provider_id, raw_sha256)
);
create unique index catalog_one_latest_record on internal.catalog_source_records(source_id, entity_kind, provider_id) where is_latest;

create table internal.catalog_field_assertions (
  id uuid primary key default gen_random_uuid(),
  source_record_id uuid not null references internal.catalog_source_records(id),
  field_name text not null,
  value jsonb not null,
  review_status text not null default 'pending' check (review_status in ('pending', 'approved', 'rejected')),
  reviewed_by text,
  reviewed_at timestamptz,
  review_note text,
  unique (source_record_id, field_name),
  check ((review_status = 'pending' and reviewed_by is null and reviewed_at is null) or
    (review_status <> 'pending' and nullif(btrim(reviewed_by), '') is not null and reviewed_at is not null))
);
create index catalog_assertions_record_idx on internal.catalog_field_assertions(source_record_id);

create table internal.catalog_entity_matches (
  source_id text not null references internal.catalog_sources(source_id),
  entity_kind text not null check (entity_kind in ('course', 'disc_mold')),
  provider_id text not null,
  canonical_id uuid,
  review_status text not null default 'candidate' check (review_status in ('candidate', 'approved', 'rejected')),
  reviewed_by text,
  reviewed_at timestamptz,
  review_note text,
  primary key (source_id, entity_kind, provider_id),
  check (review_status <> 'approved' or (canonical_id is not null and
    nullif(btrim(reviewed_by), '') is not null and reviewed_at is not null))
);
create index catalog_matches_canonical_idx on internal.catalog_entity_matches(entity_kind, canonical_id);

create table internal.catalog_promotions (
  entity_kind text not null check (entity_kind in ('course', 'disc_mold')),
  canonical_id uuid not null,
  data_version text not null references public.catalog_versions(data_version),
  values_snapshot jsonb not null,
  provenance_snapshot jsonb not null,
  promoted_by text not null check (length(btrim(promoted_by)) > 0),
  promoted_at timestamptz not null default now(),
  primary key (entity_kind, canonical_id, data_version)
);

alter table public.courses add column field_provenance jsonb not null default '{}'::jsonb;
create table public.disc_molds (
  id uuid primary key,
  name text not null check (length(btrim(name)) > 0),
  manufacturer text not null check (length(btrim(manufacturer)) > 0),
  speed numeric(4,1), glide numeric(4,1), turn numeric(4,1), fade numeric(4,1),
  data_version text not null references public.catalog_versions(data_version),
  attribution text not null,
  field_provenance jsonb not null default '{}'::jsonb,
  published boolean not null default false,
  check (speed is null or speed between 0 and 20),
  check (glide is null or glide between 0 and 10),
  check (turn is null or turn between -10 and 10),
  check (fade is null or fade between -10 and 10)
);
create table public.disc_external_ids (
  provider text not null,
  external_id text not null,
  disc_mold_id uuid not null references public.disc_molds(id),
  primary key (provider, external_id)
);
create index disc_external_ids_mold_idx on public.disc_external_ids(disc_mold_id);
alter table public.disc_molds enable row level security;
alter table public.disc_external_ids enable row level security;
create policy disc_molds_read on public.disc_molds for select to anon, authenticated using (published);
create policy disc_external_ids_read on public.disc_external_ids for select to anon, authenticated
  using (exists (select 1 from public.disc_molds m where m.id = disc_mold_id and m.published));
revoke all on public.disc_molds, public.disc_external_ids from public, anon, authenticated;
grant select on public.disc_molds, public.disc_external_ids to anon, authenticated;

-- This function stages only sources explicitly enabled in the private registry.
-- It never approves a match, assertion, or public row.
create function internal.stage_catalog_batch_v1(p_source_id text, p_run_id uuid,
    p_input_sha256 text, p_records jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_status text;
  v_existing uuid;
  v_record jsonb;
  v_record_id uuid;
  v_kind text;
  v_provider_id text;
  v_field record;
begin
  select approval_status into v_status from internal.catalog_sources where source_id = p_source_id;
  if v_status is null or v_status = 'blocked' then
    raise exception 'SOURCE_NOT_APPROVED_FOR_STAGING: %', p_source_id;
  end if;
  if p_input_sha256 !~ '^[0-9a-f]{64}$' or jsonb_typeof(p_records) <> 'array' or
     jsonb_array_length(p_records) > 1000 then
    raise exception 'INVALID_BATCH';
  end if;
  select id into v_existing from internal.catalog_import_runs
    where source_id = p_source_id and input_sha256 = p_input_sha256;
  if found then return jsonb_build_object('run_id', v_existing, 'replayed', true); end if;
  insert into internal.catalog_import_runs(id, source_id, input_sha256, record_count)
    values (p_run_id, p_source_id, p_input_sha256, jsonb_array_length(p_records));
  for v_record in select value from jsonb_array_elements(p_records) loop
    v_kind := v_record->>'entity_kind';
    v_provider_id := v_record->>'provider_id';
    if jsonb_typeof(v_record) <> 'object' or v_kind not in ('course','disc_mold') or
      v_provider_id is null or length(btrim(v_provider_id)) = 0 or
      not coalesce(v_record->>'raw_sha256' ~ '^[0-9a-f]{64}$', false) or
      jsonb_typeof(v_record->'raw') <> 'object' or
      jsonb_typeof(v_record->'fields') <> 'object' or
      (select count(*) from jsonb_object_keys(v_record->'fields')) = 0 then
      raise exception 'INVALID_RECORD: %', coalesce(v_provider_id, '<missing>');
    end if;
    if exists (select 1 from jsonb_object_keys(v_record->'fields') as f(name)
      where (v_kind = 'course' and f.name not in
        ('name','city','state','latitude','longitude','reported_hole_count')) or
            (v_kind = 'disc_mold' and f.name not in
        ('name','manufacturer','speed','glide','turn','fade'))) then
      raise exception 'UNSUPPORTED_FIELD: %', v_provider_id;
    end if;
    update internal.catalog_source_records set is_latest = false
      where source_id = p_source_id and entity_kind = v_kind and provider_id = v_provider_id
        and raw_sha256 <> v_record->>'raw_sha256' and is_latest;
    insert into internal.catalog_source_records(source_id, entity_kind, provider_id, raw_sha256,
      raw_record, observed_at, first_run_id, last_run_id)
      values (p_source_id, v_kind, v_provider_id, v_record->>'raw_sha256',
        v_record->'raw', nullif(v_record->>'observed_at','')::timestamptz, p_run_id, p_run_id)
      on conflict (source_id, entity_kind, provider_id, raw_sha256)
      do update set last_run_id = excluded.last_run_id, is_latest = true
      returning id into v_record_id;
    for v_field in select key, value from jsonb_each(v_record->'fields') loop
      insert into internal.catalog_field_assertions(source_record_id, field_name, value)
        values (v_record_id, v_field.key, v_field.value)
        on conflict (source_record_id, field_name) do nothing;
    end loop;
    insert into internal.catalog_entity_matches(source_id, entity_kind, provider_id, canonical_id)
      values (p_source_id, v_kind, v_provider_id, nullif(v_record->>'proposed_canonical_id','')::uuid)
      on conflict (source_id, entity_kind, provider_id) do nothing;
  end loop;
  return jsonb_build_object('run_id', p_run_id, 'replayed', false,
    'record_count', jsonb_array_length(p_records));
end;
$$;
revoke all on function internal.stage_catalog_batch_v1(text, uuid, text, jsonb) from public, anon, authenticated;

-- Reviewers operate in the backend with a privileged DB connection. These
-- functions require reviewed matches and assertions from rights-approved sources.
create function internal.promote_catalog_entity_v1(p_kind text, p_canonical_id uuid,
    p_data_version text, p_promoted_by text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_values jsonb;
  v_provenance jsonb;
  v_attribution text;
  v_existing internal.catalog_promotions%rowtype;
  v_name text;
  v_other text;
  v_lat double precision;
  v_lon double precision;
  v_holes integer;
begin
  if p_kind not in ('course','disc_mold') or nullif(btrim(p_promoted_by),'') is null or
    nullif(btrim(p_data_version),'') is null then raise exception 'INVALID_PROMOTION'; end if;
  if exists (
    select 1 from internal.catalog_field_assertions a
      join internal.catalog_source_records r on r.id = a.source_record_id and r.is_latest
      join internal.catalog_entity_matches m on m.source_id = r.source_id and
        m.entity_kind = r.entity_kind and m.provider_id = r.provider_id and
        m.canonical_id = p_canonical_id and m.review_status = 'approved'
      join internal.catalog_sources s on s.source_id = r.source_id and s.approval_status = 'public_approved'
      where r.entity_kind = p_kind and a.review_status <> 'rejected'
      group by a.field_name having count(distinct a.value) > 1
  ) then raise exception 'UNRESOLVED_FIELD_CONFLICT'; end if;
  select jsonb_object_agg(a.field_name, a.value),
    jsonb_object_agg(a.field_name, jsonb_build_object('source_id', r.source_id,
      'provider_id', r.provider_id, 'raw_sha256', r.raw_sha256,
      'observed_at', r.observed_at, 'reviewed_by', a.reviewed_by,
      'reviewed_at', a.reviewed_at)),
    string_agg(distinct s.attribution, '; ')
    into v_values, v_provenance, v_attribution
    from internal.catalog_field_assertions a
    join internal.catalog_source_records r on r.id = a.source_record_id and r.is_latest
    join internal.catalog_entity_matches m on m.source_id = r.source_id and
      m.entity_kind = r.entity_kind and m.provider_id = r.provider_id and
      m.canonical_id = p_canonical_id and m.review_status = 'approved'
    join internal.catalog_sources s on s.source_id = r.source_id and s.approval_status = 'public_approved'
    where r.entity_kind = p_kind and a.review_status = 'approved';
  if v_values is null then raise exception 'NO_APPROVED_FIELDS'; end if;
  v_name := nullif(btrim(v_values->>'name'),'');
  if v_name is null then raise exception 'NAME_NOT_REVIEWED'; end if;
  select * into v_existing from internal.catalog_promotions
    where entity_kind = p_kind and canonical_id = p_canonical_id and data_version = p_data_version;
  if found then
    if v_existing.values_snapshot <> v_values or v_existing.provenance_snapshot <> v_provenance then
      raise exception 'VERSION_ALREADY_PROMOTED_WITH_DIFFERENT_FACTS';
    end if;
    return jsonb_build_object('canonical_id', p_canonical_id, 'replayed', true);
  end if;
  insert into public.catalog_versions(data_version) values (p_data_version) on conflict do nothing;
  if p_kind = 'course' then
    v_other := nullif(btrim(v_values->>'city'),'');
    if v_other is null or nullif(btrim(v_values->>'state'),'') is null then
      raise exception 'COURSE_LOCALITY_NOT_REVIEWED'; end if;
    if (v_values ? 'latitude') and (v_values ? 'longitude') then
      v_lat := (v_values->>'latitude')::double precision;
      v_lon := (v_values->>'longitude')::double precision;
    end if;
    if v_values ? 'reported_hole_count' then v_holes := (v_values->>'reported_hole_count')::integer; end if;
    if exists (select 1 from public.courses where id = p_canonical_id and synthetic) then
      raise exception 'CANNOT_PROMOTE_SYNTHETIC_COURSE'; end if;
    if exists (select 1 from internal.catalog_entity_matches m
      join public.course_external_ids e on e.provider=m.source_id and e.external_id=m.provider_id
      where m.entity_kind='course' and m.canonical_id=p_canonical_id and m.review_status='approved'
        and e.course_id <> p_canonical_id) then raise exception 'EXTERNAL_ID_CONFLICT'; end if;
    insert into public.courses(id,name,city,state,latitude,longitude,reported_hole_count,
      reported_hole_count_provenance,attribution,data_version,published,synthetic,field_provenance)
      values (p_canonical_id,v_name,v_other,v_values->>'state',v_lat,v_lon,v_holes,
        v_provenance->'reported_hole_count',v_attribution,p_data_version,true,false,v_provenance)
      on conflict (id) do update set name=excluded.name,city=excluded.city,state=excluded.state,
        latitude=excluded.latitude,longitude=excluded.longitude,reported_hole_count=excluded.reported_hole_count,
        reported_hole_count_provenance=excluded.reported_hole_count_provenance,
        attribution=excluded.attribution,data_version=excluded.data_version,published=true,
        field_provenance=excluded.field_provenance;
    insert into public.course_external_ids(provider,external_id,course_id)
      select m.source_id,m.provider_id,p_canonical_id from internal.catalog_entity_matches m
      join internal.catalog_sources s on s.source_id=m.source_id and s.approval_status='public_approved'
      where m.entity_kind='course' and m.canonical_id=p_canonical_id and m.review_status='approved'
      on conflict (provider,external_id) do nothing;
  else
    v_other := nullif(btrim(v_values->>'manufacturer'),'');
    if v_other is null then raise exception 'DISC_MANUFACTURER_NOT_REVIEWED'; end if;
    if exists (select 1 from internal.catalog_entity_matches m
      join public.disc_external_ids e on e.provider=m.source_id and e.external_id=m.provider_id
      where m.entity_kind='disc_mold' and m.canonical_id=p_canonical_id and m.review_status='approved'
        and e.disc_mold_id <> p_canonical_id) then raise exception 'EXTERNAL_ID_CONFLICT'; end if;
    insert into public.disc_molds(id,name,manufacturer,speed,glide,turn,fade,
      data_version,attribution,field_provenance,published)
      values (p_canonical_id,v_name,v_other,(v_values->>'speed')::numeric,
        (v_values->>'glide')::numeric,(v_values->>'turn')::numeric,(v_values->>'fade')::numeric,
        p_data_version,v_attribution,v_provenance,true)
      on conflict (id) do update set name=excluded.name,manufacturer=excluded.manufacturer,
        speed=excluded.speed,glide=excluded.glide,turn=excluded.turn,fade=excluded.fade,
        data_version=excluded.data_version,attribution=excluded.attribution,
        field_provenance=excluded.field_provenance,published=true;
    insert into public.disc_external_ids(provider,external_id,disc_mold_id)
      select m.source_id,m.provider_id,p_canonical_id from internal.catalog_entity_matches m
      join internal.catalog_sources s on s.source_id=m.source_id and s.approval_status='public_approved'
      where m.entity_kind='disc_mold' and m.canonical_id=p_canonical_id and m.review_status='approved'
      on conflict (provider,external_id) do nothing;
  end if;
  insert into internal.catalog_promotions(entity_kind,canonical_id,data_version,
    values_snapshot,provenance_snapshot,promoted_by)
    values (p_kind,p_canonical_id,p_data_version,v_values,v_provenance,p_promoted_by);
  return jsonb_build_object('canonical_id', p_canonical_id, 'replayed', false,
    'data_version', p_data_version);
end;
$$;
revoke all on function internal.promote_catalog_entity_v1(text, uuid, text, text) from public, anon, authenticated;
