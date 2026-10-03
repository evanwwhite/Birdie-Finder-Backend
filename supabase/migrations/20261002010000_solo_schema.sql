-- Version-one internal solo-round schema. Public catalog rows below are synthetic only.
create table public.catalog_versions (
  data_version text primary key,
  published_at timestamptz not null default now()
);

create table public.courses (
  id uuid primary key,
  name text not null check (length(btrim(name)) > 0),
  city text not null,
  state text not null,
  latitude double precision,
  longitude double precision,
  reported_hole_count integer check (reported_hole_count between 1 and 36),
  reported_hole_count_provenance jsonb,
  attribution text,
  data_version text not null references public.catalog_versions(data_version),
  published boolean not null default false,
  synthetic boolean not null default false,
  check ((latitude is null) = (longitude is null)),
  check (latitude is null or (latitude between -90 and 90 and longitude between -180 and 180))
);

create table public.course_external_ids (
  provider text not null,
  external_id text not null,
  course_id uuid not null references public.courses(id) on delete cascade,
  primary key (provider, external_id),
  check (length(btrim(provider)) > 0 and length(btrim(external_id)) > 0)
);
create index course_external_ids_course_idx on public.course_external_ids(course_id);

create table public.layouts (
  id uuid primary key,
  course_id uuid not null references public.courses(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  unique (course_id, name)
);

create table public.layout_versions (
  id uuid primary key,
  layout_id uuid not null references public.layouts(id) on delete cascade,
  version_no integer not null check (version_no > 0),
  data_version text not null references public.catalog_versions(data_version),
  published boolean not null default false,
  unique (layout_id, version_no)
);

create table public.layout_holes (
  id uuid primary key,
  layout_version_id uuid not null references public.layout_versions(id) on delete cascade,
  hole_number integer not null check (hole_number between 1 and 36),
  par integer check (par between 2 and 6),
  distance_ft integer check (distance_ft > 0),
  par_provenance jsonb,
  distance_provenance jsonb,
  unique (layout_version_id, hole_number),
  check ((par is null) = (par_provenance is null)),
  check ((distance_ft is null) = (distance_provenance is null))
);

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  handle text,
  created_at timestamptz not null default now(),
  check (handle is null or length(btrim(handle)) between 1 and 40)
);

create table public.rounds (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  course_id uuid not null references public.courses(id),
  layout_version_id uuid references public.layout_versions(id),
  layout_name text not null,
  data_version text not null references public.catalog_versions(data_version),
  status text not null default 'live' check (status in ('live', 'complete', 'abandoned')),
  revision bigint not null default 0 check (revision >= 0),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  create_request jsonb not null,
  create_ack jsonb,
  check ((status = 'complete') = (completed_at is not null))
);
create index rounds_owner_started_idx on public.rounds(owner_id, started_at desc, id);

create table public.round_participants (
  id uuid primary key,
  round_id uuid not null references public.rounds(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  is_owner boolean not null default false,
  unique (round_id, id),
  unique (round_id, user_id)
);
create unique index one_owner_per_round on public.round_participants(round_id) where is_owner;

create table public.round_hole_snapshots (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.rounds(id) on delete cascade,
  source_layout_hole_id uuid references public.layout_holes(id),
  hole_number integer not null check (hole_number between 1 and 36),
  par integer check (par between 2 and 6),
  distance_ft integer check (distance_ft > 0),
  par_source text check (par_source in ('catalog', 'user_entered')),
  par_provenance jsonb,
  distance_provenance jsonb,
  unique (round_id, id),
  unique (round_id, hole_number),
  check ((par is null) = (par_source is null)),
  check ((par is null) = (par_provenance is null)),
  check ((distance_ft is null) = (distance_provenance is null))
);

create table public.hole_scores (
  round_id uuid not null,
  round_participant_id uuid not null,
  snapshot_hole_id uuid not null,
  strokes integer not null check (strokes between 1 and 12),
  updated_at timestamptz not null default now(),
  primary key (round_id, round_participant_id, snapshot_hole_id),
  foreign key (round_id, round_participant_id) references public.round_participants(round_id, id) on delete cascade,
  foreign key (round_id, snapshot_hole_id) references public.round_hole_snapshots(round_id, id) on delete cascade
);

create table internal.mutation_receipts (
  owner_id uuid not null references auth.users(id) on delete cascade,
  mutation_id uuid not null,
  round_id uuid not null references public.rounds(id) on delete cascade,
  operation text not null check (operation in ('score', 'complete')),
  request jsonb not null,
  acknowledgement jsonb not null,
  created_at timestamptz not null default now(),
  primary key (owner_id, mutation_id)
);

-- Supabase's public schema exists already; all client access is explicit.
revoke all on public.catalog_versions, public.courses, public.course_external_ids,
  public.layouts, public.layout_versions, public.layout_holes, public.profiles,
  public.rounds, public.round_participants, public.round_hole_snapshots,
  public.hole_scores from public, anon, authenticated;
revoke all on internal.mutation_receipts from public, anon, authenticated;

alter table public.catalog_versions enable row level security;
alter table public.courses enable row level security;
alter table public.course_external_ids enable row level security;
alter table public.layouts enable row level security;
alter table public.layout_versions enable row level security;
alter table public.layout_holes enable row level security;
alter table public.profiles enable row level security;
alter table public.rounds enable row level security;
alter table public.round_participants enable row level security;
alter table public.round_hole_snapshots enable row level security;
alter table public.hole_scores enable row level security;
alter table internal.mutation_receipts enable row level security;

create policy catalog_versions_read on public.catalog_versions for select to anon, authenticated using (true);
create policy courses_read on public.courses for select to anon, authenticated using (published);
create policy external_ids_read on public.course_external_ids for select to anon, authenticated
  using (exists (select 1 from public.courses c where c.id = course_id and c.published));
create policy layouts_read on public.layouts for select to anon, authenticated
  using (exists (select 1 from public.courses c where c.id = course_id and c.published));
create policy layout_versions_read on public.layout_versions for select to anon, authenticated
  using (published and exists (select 1 from public.layouts l join public.courses c on c.id = l.course_id where l.id = layout_id and c.published));
create policy layout_holes_read on public.layout_holes for select to anon, authenticated
  using (exists (select 1 from public.layout_versions v where v.id = layout_version_id and v.published));
create policy profiles_owner on public.profiles for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy rounds_owner_read on public.rounds for select to authenticated using (owner_id = (select auth.uid()));
create policy participants_owner_read on public.round_participants for select to authenticated
  using (exists (select 1 from public.rounds r where r.id = round_id and r.owner_id = (select auth.uid())));
create policy snapshots_owner_read on public.round_hole_snapshots for select to authenticated
  using (exists (select 1 from public.rounds r where r.id = round_id and r.owner_id = (select auth.uid())));
create policy scores_owner_read on public.hole_scores for select to authenticated
  using (exists (select 1 from public.rounds r where r.id = round_id and r.owner_id = (select auth.uid())));

grant select on public.catalog_versions, public.courses, public.course_external_ids,
  public.layouts, public.layout_versions, public.layout_holes to anon, authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select on public.rounds, public.round_participants, public.round_hole_snapshots,
  public.hole_scores to authenticated;
