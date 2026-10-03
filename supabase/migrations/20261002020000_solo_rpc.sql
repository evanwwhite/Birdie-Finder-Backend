-- All client writes are owner-checked transactions. Helpers are confined to internal.
create function internal.error_v1(p_code text, p_message text, p_details jsonb default null)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('error', jsonb_build_object('code', p_code, 'message', p_message) ||
    case when p_details is null then '{}'::jsonb else jsonb_build_object('details', p_details) end);
$$;
revoke all on function internal.error_v1(text, text, jsonb) from public, anon, authenticated;

create function internal.parse_integer_v1(p_text text)
returns integer language plpgsql immutable strict set search_path = '' as $$
begin
  if p_text !~ '^[0-9]+$' then return null; end if;
  return p_text::integer;
exception when invalid_text_representation or numeric_value_out_of_range then
  return null;
end;
$$;
create function internal.parse_bigint_v1(p_text text)
returns bigint language plpgsql immutable strict set search_path = '' as $$
begin
  if p_text !~ '^[0-9]+$' then return null; end if;
  return p_text::bigint;
exception when invalid_text_representation or numeric_value_out_of_range then
  return null;
end;
$$;
revoke all on function internal.parse_integer_v1(text), internal.parse_bigint_v1(text) from public, anon, authenticated;

create function internal.round_document_v1(p_round_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_round public.rounds%rowtype;
  v_participant uuid;
  v_holes jsonb;
  v_scores jsonb;
  v_played integer;
  v_total integer;
  v_par_total integer;
  v_unknown_par boolean;
begin
  select * into v_round from public.rounds where id = p_round_id;
  if not found then return null; end if;
  select id into v_participant from public.round_participants
    where round_id = p_round_id and is_owner;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', h.id, 'hole_number', h.hole_number,
      'source_layout_hole_id', h.source_layout_hole_id,
      'par', h.par, 'distance_ft', h.distance_ft, 'par_source', h.par_source,
      'par_provenance', h.par_provenance, 'distance_provenance', h.distance_provenance
    ) order by h.hole_number), '[]'::jsonb),
    coalesce(bool_or(h.par is null or h.par_source = 'user_entered'), true),
    sum(h.par)
    into v_holes, v_unknown_par, v_par_total
    from public.round_hole_snapshots h where h.round_id = p_round_id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'snapshot_hole_id', h.id, 'hole_number', h.hole_number, 'strokes', s.strokes
    ) order by h.hole_number), '[]'::jsonb),
    count(s.strokes), sum(s.strokes)
    into v_scores, v_played, v_total
    from public.round_hole_snapshots h
    left join public.hole_scores s on s.round_id = h.round_id
      and s.snapshot_hole_id = h.id and s.round_participant_id = v_participant
    where h.round_id = p_round_id;
  return jsonb_build_object(
    'id', v_round.id, 'owner_user_id', v_round.owner_id,
    'participant_id', v_participant, 'course_id', v_round.course_id,
    'layout_version_id', v_round.layout_version_id, 'layout_name', v_round.layout_name,
    'data_version', v_round.data_version, 'status', v_round.status,
    'revision', v_round.revision, 'started_at', v_round.started_at,
    'completed_at', v_round.completed_at, 'holes', v_holes, 'scores', v_scores,
    'played_holes', v_played,
    'total_strokes', case when v_round.status = 'complete' then v_total else null end,
    'vs_par', case when v_round.status = 'complete' and not v_unknown_par
      then v_total - v_par_total else null end
  );
end;
$$;
revoke all on function internal.round_document_v1(uuid) from public, anon, authenticated;

create function public.create_solo_round_v1(p_request jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid := auth.uid();
  v_round_id uuid;
  v_participant_id uuid;
  v_course_id uuid;
  v_layout_version_id uuid;
  v_data_version text;
  v_layout_name text;
  v_holes jsonb;
  v_existing public.rounds%rowtype;
  v_inserted uuid;
  v_ack jsonb;
begin
  if v_owner is null then
    return internal.error_v1('UNAUTHENTICATED', 'Sign in to save a round.');
  end if;
  if jsonb_typeof(p_request) <> 'object' or
    not coalesce(p_request->>'round_id' ~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$', false) or
    not coalesce(p_request->>'participant_id' ~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$', false) or
    not coalesce(p_request->>'course_id' ~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$', false) then
    return internal.error_v1('INVALID_REQUEST', 'Valid round, participant, and course UUIDs are required.');
  end if;
  v_round_id := (p_request->>'round_id')::uuid;
  v_participant_id := (p_request->>'participant_id')::uuid;
  v_course_id := (p_request->>'course_id')::uuid;
  select * into v_existing from public.rounds where id = v_round_id;
  if found then
    if v_existing.owner_id <> v_owner then
      return internal.error_v1('NOT_FOUND', 'Round not found.');
    elsif v_existing.create_request = p_request then
      return v_existing.create_ack;
    else
      return internal.error_v1('IDEMPOTENCY_CONFLICT', 'Round ID was used with different data.');
    end if;
  end if;
  select data_version into v_data_version from public.courses
    where id = v_course_id and published;
  if not found then return internal.error_v1('NOT_FOUND', 'Course not found.'); end if;
  if p_request->>'layout_version_id' is not null then
    if not coalesce(p_request->>'layout_version_id' ~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$', false)
       or p_request->'custom_layout' <> 'null'::jsonb then
      return internal.error_v1('INVALID_REQUEST', 'Choose one published or custom layout.');
    end if;
    v_layout_version_id := (p_request->>'layout_version_id')::uuid;
    select l.name into v_layout_name from public.layout_versions lv
      join public.layouts l on l.id = lv.layout_id
      where lv.id = v_layout_version_id and lv.published and l.course_id = v_course_id;
    if not found then return internal.error_v1('NOT_FOUND', 'Layout not found.'); end if;
    if not exists (select 1 from public.layout_holes where layout_version_id = v_layout_version_id) then
      return internal.error_v1('INVALID_REQUEST', 'Layout has no holes.');
    end if;
  else
    if jsonb_typeof(p_request->'custom_layout') <> 'object' or
      jsonb_typeof(p_request#>'{custom_layout,holes}') <> 'array' then
      return internal.error_v1('INVALID_REQUEST', 'A private custom layout is required.');
    end if;
    v_layout_name := btrim(p_request#>>'{custom_layout,name}');
    v_holes := p_request#>'{custom_layout,holes}';
    if v_layout_name is null or length(v_layout_name) not between 1 and 80 or
      jsonb_array_length(v_holes) not between 1 and 36 then
      return internal.error_v1('INVALID_REQUEST', 'Confirm a name and 1 to 36 holes.');
    end if;
    if exists (
      select 1 from jsonb_array_elements(v_holes) with ordinality as e(hole, position)
      where jsonb_typeof(e.hole) <> 'object'
        or jsonb_typeof(e.hole->'hole_number') <> 'number'
        or not coalesce(e.hole->>'hole_number' ~ '^[0-9]+$', false)
        or e.hole->>'hole_number' <> e.position::text
        or not (e.hole ? 'par') or not (e.hole ? 'distance_ft')
        or (e.hole->'par' <> 'null'::jsonb and (
          jsonb_typeof(e.hole->'par') <> 'number' or
          not coalesce(internal.parse_integer_v1(e.hole->>'par') between 2 and 6, false)))
        or (e.hole->'distance_ft' <> 'null'::jsonb and (
          jsonb_typeof(e.hole->'distance_ft') <> 'number' or
          not coalesce(internal.parse_integer_v1(e.hole->>'distance_ft') > 0, false)))
    ) then
      return internal.error_v1('INVALID_REQUEST', 'Custom holes must be sequential with valid par and distance.');
    end if;
  end if;
  insert into public.rounds(id, owner_id, course_id, layout_version_id,
    layout_name, data_version, create_request)
    values (v_round_id, v_owner, v_course_id, v_layout_version_id,
      v_layout_name, v_data_version, p_request)
    on conflict (id) do nothing returning id into v_inserted;
  if v_inserted is null then
    select * into v_existing from public.rounds where id = v_round_id;
    if v_existing.owner_id <> v_owner then return internal.error_v1('NOT_FOUND', 'Round not found.'); end if;
    if v_existing.create_request <> p_request then
      return internal.error_v1('IDEMPOTENCY_CONFLICT', 'Round ID was used with different data.');
    end if;
    return v_existing.create_ack;
  end if;
  insert into public.round_participants(id, round_id, user_id, is_owner)
    values (v_participant_id, v_round_id, v_owner, true);
  if v_layout_version_id is not null then
    insert into public.round_hole_snapshots(round_id, source_layout_hole_id,
      hole_number, par, distance_ft, par_source, par_provenance, distance_provenance)
    select v_round_id, h.id, h.hole_number, h.par, h.distance_ft,
      case when h.par is not null then 'catalog' else null end,
      h.par_provenance, h.distance_provenance
      from public.layout_holes h where h.layout_version_id = v_layout_version_id
      order by h.hole_number;
  else
    insert into public.round_hole_snapshots(round_id, hole_number, par,
      distance_ft, par_source, par_provenance, distance_provenance)
    select v_round_id, e.position::integer,
      internal.parse_integer_v1(e.hole->>'par'), internal.parse_integer_v1(e.hole->>'distance_ft'),
      case when e.hole->>'par' is not null then 'user_entered' else null end,
      case when e.hole->>'par' is not null then '{"source_type":"user_entered","verification":"unverified"}'::jsonb else null end,
      case when e.hole->>'distance_ft' is not null then '{"source_type":"user_entered","verification":"unverified"}'::jsonb else null end
      from jsonb_array_elements(v_holes) with ordinality as e(hole, position);
  end if;
  v_ack := jsonb_build_object('data', internal.round_document_v1(v_round_id));
  update public.rounds set create_ack = v_ack where id = v_round_id;
  return v_ack;
end;
$$;

create function public.write_score_v1(p_request jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid := auth.uid();
  v_round_id uuid;
  v_participant_id uuid;
  v_mutation_id uuid;
  v_hole_number integer;
  v_strokes integer;
  v_expected bigint;
  v_round public.rounds%rowtype;
  v_snapshot_id uuid;
  v_current_strokes integer;
  v_receipt internal.mutation_receipts%rowtype;
  v_ack jsonb;
begin
  if v_owner is null then return internal.error_v1('UNAUTHENTICATED', 'Sign in to score.'); end if;
  if jsonb_typeof(p_request) <> 'object' or
    not coalesce(p_request->>'round_id' ~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$', false) or
    not coalesce(p_request->>'participant_id' ~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$', false) or
    not coalesce(p_request->>'mutation_id' ~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$', false) or
    not coalesce(p_request->>'hole_number' ~ '^[0-9]+$', false) or
    not coalesce(p_request->>'expected_revision' ~ '^[0-9]+$', false) then
    return internal.error_v1('INVALID_REQUEST', 'Round, participant, hole, mutation, and revision are required.');
  end if;
  v_round_id := (p_request->>'round_id')::uuid;
  v_participant_id := (p_request->>'participant_id')::uuid;
  v_mutation_id := (p_request->>'mutation_id')::uuid;
  v_hole_number := internal.parse_integer_v1(p_request->>'hole_number');
  v_expected := internal.parse_bigint_v1(p_request->>'expected_revision');
  if v_hole_number is null or v_hole_number not between 1 and 36 or v_expected is null then
    return internal.error_v1('INVALID_REQUEST', 'Hole and revision must be valid nonnegative integers.');
  end if;
  select * into v_round from public.rounds where id = v_round_id for update;
  if not found or v_round.owner_id <> v_owner then
    return internal.error_v1('NOT_FOUND', 'Round not found.');
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_owner::text || ':' || v_mutation_id::text, 0));
  select * into v_receipt from internal.mutation_receipts
    where owner_id = v_owner and mutation_id = v_mutation_id;
  if found then
    if v_receipt.operation = 'score' and v_receipt.request = p_request then
      return v_receipt.acknowledgement;
    end if;
    return internal.error_v1('IDEMPOTENCY_CONFLICT', 'Mutation ID was used with different data.');
  end if;
  if not exists (select 1 from public.round_participants
      where id = v_participant_id and round_id = v_round_id and user_id = v_owner and is_owner) then
    return internal.error_v1('INVALID_REQUEST', 'Participant is not the round owner.');
  end if;
  select id into v_snapshot_id from public.round_hole_snapshots
    where round_id = v_round_id and hole_number = v_hole_number;
  if not found then return internal.error_v1('INVALID_REQUEST', 'Hole is not in the round.'); end if;
  v_strokes := internal.parse_integer_v1(p_request->>'strokes');
  if jsonb_typeof(p_request->'strokes') <> 'number' or
    not coalesce(v_strokes between 1 and 12, false) then
    return internal.error_v1('INVALID_SCORE', 'Strokes must be an integer from 1 to 12.');
  end if;
  if v_round.status = 'abandoned' then
    return internal.error_v1('INVALID_REQUEST', 'An abandoned round cannot be scored.');
  end if;
  if v_round.revision <> v_expected then
    select strokes into v_current_strokes from public.hole_scores
      where round_id = v_round_id and round_participant_id = v_participant_id
        and snapshot_hole_id = v_snapshot_id;
    return internal.error_v1('STALE_REVISION', 'The round changed. Refresh it before editing this score.',
      jsonb_build_object('round_id', v_round_id, 'participant_id', v_participant_id,
        'hole_number', v_hole_number, 'expected_revision', v_expected,
        'current_revision', v_round.revision, 'current_strokes', v_current_strokes));
  end if;
  insert into public.hole_scores(round_id, round_participant_id, snapshot_hole_id, strokes)
    values (v_round_id, v_participant_id, v_snapshot_id, v_strokes)
    on conflict (round_id, round_participant_id, snapshot_hole_id)
    do update set strokes = excluded.strokes, updated_at = now();
  update public.rounds set revision = revision + 1 where id = v_round_id
    returning revision, status into v_round.revision, v_round.status;
  v_ack := jsonb_build_object('data', jsonb_build_object(
    'round_id', v_round_id, 'participant_id', v_participant_id,
    'snapshot_hole_id', v_snapshot_id, 'hole_number', v_hole_number,
    'mutation_id', v_mutation_id, 'strokes', v_strokes,
    'revision', v_round.revision, 'status', v_round.status));
  insert into internal.mutation_receipts(owner_id, mutation_id, round_id, operation, request, acknowledgement)
    values (v_owner, v_mutation_id, v_round_id, 'score', p_request, v_ack);
  return v_ack;
end;
$$;

create function public.complete_round_v1(p_request jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid := auth.uid();
  v_round_id uuid;
  v_mutation_id uuid;
  v_expected bigint;
  v_round public.rounds%rowtype;
  v_participant uuid;
  v_missing jsonb;
  v_receipt internal.mutation_receipts%rowtype;
  v_ack jsonb;
begin
  if v_owner is null then return internal.error_v1('UNAUTHENTICATED', 'Sign in to finish a round.'); end if;
  if jsonb_typeof(p_request) <> 'object' or
    not coalesce(p_request->>'round_id' ~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$', false) or
    not coalesce(p_request->>'mutation_id' ~ '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$', false) or
    not coalesce(p_request->>'expected_revision' ~ '^[0-9]+$', false) then
    return internal.error_v1('INVALID_REQUEST', 'Round, mutation, and revision are required.');
  end if;
  v_round_id := (p_request->>'round_id')::uuid;
  v_mutation_id := (p_request->>'mutation_id')::uuid;
  v_expected := internal.parse_bigint_v1(p_request->>'expected_revision');
  if v_expected is null then
    return internal.error_v1('INVALID_REQUEST', 'Revision must be a valid nonnegative integer.');
  end if;
  select * into v_round from public.rounds where id = v_round_id for update;
  if not found or v_round.owner_id <> v_owner then
    return internal.error_v1('NOT_FOUND', 'Round not found.');
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_owner::text || ':' || v_mutation_id::text, 0));
  select * into v_receipt from internal.mutation_receipts
    where owner_id = v_owner and mutation_id = v_mutation_id;
  if found then
    if v_receipt.operation = 'complete' and v_receipt.request = p_request then
      return v_receipt.acknowledgement;
    end if;
    return internal.error_v1('IDEMPOTENCY_CONFLICT', 'Mutation ID was used with different data.');
  end if;
  if v_round.status <> 'live' then
    return internal.error_v1('INVALID_REQUEST', 'Only a live round can be completed.');
  end if;
  if v_round.revision <> v_expected then
    return internal.error_v1('STALE_REVISION', 'The round changed. Refresh it before finishing.',
      jsonb_build_object('round_id', v_round_id, 'expected_revision', v_expected,
        'current_revision', v_round.revision));
  end if;
  select id into v_participant from public.round_participants
    where round_id = v_round_id and user_id = v_owner and is_owner;
  select coalesce(jsonb_agg(h.hole_number order by h.hole_number), '[]'::jsonb)
    into v_missing from public.round_hole_snapshots h
    left join public.hole_scores s on s.round_id = h.round_id
      and s.snapshot_hole_id = h.id and s.round_participant_id = v_participant
    where h.round_id = v_round_id and s.strokes is null;
  if v_missing <> '[]'::jsonb then
    return internal.error_v1('INCOMPLETE_ROUND', 'Record every hole before finishing.',
      jsonb_build_object('missing_holes', v_missing));
  end if;
  update public.rounds set status = 'complete', completed_at = now(), revision = revision + 1
    where id = v_round_id;
  v_ack := jsonb_build_object('data', internal.round_document_v1(v_round_id));
  insert into internal.mutation_receipts(owner_id, mutation_id, round_id, operation, request, acknowledgement)
    values (v_owner, v_mutation_id, v_round_id, 'complete', p_request, v_ack);
  return v_ack;
end;
$$;

revoke all on function public.create_solo_round_v1(jsonb), public.write_score_v1(jsonb),
  public.complete_round_v1(jsonb) from public, anon, authenticated;
grant execute on function public.create_solo_round_v1(jsonb), public.write_score_v1(jsonb),
  public.complete_round_v1(jsonb) to authenticated;
