-- Public catalog reads exclude the local synthetic seed. All functions are
-- invoker-security and use the same published rows for both clients.
create function public.search_courses_v1(p_query text default '', p_lat double precision default null,
  p_lon double precision default null, p_limit integer default 20, p_offset integer default 0)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare v_result jsonb;
begin
  if p_limit not between 1 and 50 or p_offset not between 0 and 10000 or
     length(coalesce(p_query,'')) > 100 or
     ((p_lat is null) <> (p_lon is null)) or
     (p_lat is not null and (p_lat not between -90 and 90 or p_lon not between -180 and 180)) then
    raise exception 'INVALID_CATALOG_SEARCH';
  end if;
  with matches as (
    select c.*, case when p_lat is not null and c.latitude is not null then
      3958.7613 * 2 * asin(sqrt(least(1.0, greatest(0.0,
        power(sin(radians((c.latitude-p_lat)/2)),2) +
        cos(radians(p_lat))*cos(radians(c.latitude))*power(sin(radians((c.longitude-p_lon)/2)),2)))))
      else null end as distance_mi
    from public.courses c
    where c.published and not c.synthetic and
      (coalesce(btrim(p_query),'') = '' or c.name ilike '%' || p_query || '%' or
       c.city ilike '%' || p_query || '%' or c.state ilike '%' || p_query || '%')
  ), page as (
    select * from matches order by distance_mi asc nulls last, name, id limit p_limit offset p_offset
  )
  select jsonb_build_object('total', (select count(*) from matches), 'offset', p_offset,
    'limit', p_limit, 'items', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'city', city, 'state', state, 'latitude', latitude,
      'longitude', longitude, 'reported_hole_count', reported_hole_count,
      'data_version', data_version, 'attribution', attribution,
      'field_provenance', field_provenance, 'distance_mi', distance_mi)
      order by distance_mi asc nulls last, name, id) from page), '[]'::jsonb)) into v_result;
  return v_result;
end;
$$;

create function public.get_course_detail_v1(p_id uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object('id',c.id,'name',c.name,'city',c.city,'state',c.state,
    'latitude',c.latitude,'longitude',c.longitude,'reported_hole_count',c.reported_hole_count,
    'data_version',c.data_version,'attribution',c.attribution,
    'field_provenance',c.field_provenance,
    'layouts',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'name',l.name,
      'versions',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'version_no',v.version_no,
        'data_version',v.data_version,'holes',coalesce((select jsonb_agg(jsonb_build_object(
          'id',h.id,'hole_number',h.hole_number,'par',h.par,'distance_ft',h.distance_ft,
          'par_provenance',h.par_provenance,'distance_provenance',h.distance_provenance)
          order by h.hole_number) from public.layout_holes h where h.layout_version_id=v.id),'[]'::jsonb))
        order by v.version_no desc) from public.layout_versions v where v.layout_id=l.id and v.published),'[]'::jsonb))
      order by l.name) from public.layouts l where l.course_id=c.id),'[]'::jsonb))
  from public.courses c where c.id=p_id and c.published and not c.synthetic;
$$;

create function public.search_disc_molds_v1(p_query text default '', p_limit integer default 20,
  p_offset integer default 0)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare v_result jsonb;
begin
  if p_limit not between 1 and 50 or p_offset not between 0 and 10000 or
     length(coalesce(p_query,'')) > 100 then raise exception 'INVALID_CATALOG_SEARCH'; end if;
  with matches as (
    select * from public.disc_molds where published and
      (coalesce(btrim(p_query),'') = '' or name ilike '%' || p_query || '%' or
       manufacturer ilike '%' || p_query || '%')
  ), page as (select * from matches order by manufacturer,name,id limit p_limit offset p_offset)
  select jsonb_build_object('total',(select count(*) from matches),'offset',p_offset,
    'limit',p_limit,'items',coalesce((select jsonb_agg(jsonb_build_object('id',id,
      'name',name,'manufacturer',manufacturer,'speed',speed,'glide',glide,
      'turn',turn,'fade',fade,'data_version',data_version,'attribution',attribution,
      'field_provenance',field_provenance) order by manufacturer,name,id) from page),'[]'::jsonb))
    into v_result;
  return v_result;
end;
$$;

revoke all on function public.search_courses_v1(text,double precision,double precision,integer,integer),
  public.get_course_detail_v1(uuid),public.search_disc_molds_v1(text,integer,integer) from public;
grant execute on function public.search_courses_v1(text,double precision,double precision,integer,integer),
  public.get_course_detail_v1(uuid),public.search_disc_molds_v1(text,integer,integer) to anon,authenticated;
