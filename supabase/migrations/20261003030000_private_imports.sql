-- Private bag and per-record legacy import acknowledgements.
create table public.bag_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  disc_mold_id uuid not null references public.disc_molds(id),
  added_at timestamptz not null default now()
);
create index bag_items_owner_idx on public.bag_items(owner_id);
alter table public.bag_items enable row level security;
create policy bag_owner on public.bag_items for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()) and
    exists (select 1 from public.disc_molds m where m.id=disc_mold_id and m.published));
revoke all on public.bag_items from public,anon,authenticated;
grant select,insert,update,delete on public.bag_items to authenticated;

create table internal.legacy_import_receipts (
  owner_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  record_id uuid not null,
  record_kind text not null check (record_kind in ('web_round','app_round','app_bag_disc')),
  source_sha256 text not null check (source_sha256 ~ '^[0-9a-f]{64}$'),
  played_at timestamptz,
  round_id uuid references public.rounds(id) on delete cascade,
  bag_item_id uuid references public.bag_items(id) on delete cascade,
  acknowledged_at timestamptz not null default now(),
  primary key (owner_id, device_id, record_id),
  check ((record_kind in ('web_round','app_round') and round_id is not null and bag_item_id is null) or
         (record_kind='app_bag_disc' and bag_item_id is not null and round_id is null and played_at is null))
);
alter table internal.legacy_import_receipts enable row level security;
revoke all on internal.legacy_import_receipts from public,anon,authenticated;

create function public.ack_legacy_import_v1(p_device_id uuid,p_record_id uuid,p_record_kind text,
  p_source_sha256 text,p_target_id uuid,p_played_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := (select auth.uid()); v_existing internal.legacy_import_receipts%rowtype;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_device_id is null or p_record_id is null or p_source_sha256 !~ '^[0-9a-f]{64}$' or
     p_record_kind not in ('web_round','app_round','app_bag_disc') or
     (p_played_at is not null and (p_record_kind='app_bag_disc' or p_played_at>now()+interval '1 day')) then
    raise exception 'INVALID_IMPORT_RECEIPT'; end if;
  select * into v_existing from internal.legacy_import_receipts
    where owner_id=v_user and device_id=p_device_id and record_id=p_record_id;
  if found then
    if v_existing.record_kind<>p_record_kind or v_existing.source_sha256<>p_source_sha256 or
       v_existing.played_at is distinct from p_played_at or
       coalesce(v_existing.round_id,v_existing.bag_item_id)<>p_target_id then
      raise exception 'IMPORT_RECEIPT_CONFLICT'; end if;
    return jsonb_build_object('record_id',p_record_id,'target_id',p_target_id,'replayed',true);
  end if;
  if p_record_kind='app_bag_disc' then
    if not exists(select 1 from public.bag_items where id=p_target_id and owner_id=v_user) then
      raise exception 'IMPORT_TARGET_NOT_VISIBLE'; end if;
  elsif not exists(select 1 from public.rounds where id=p_target_id and owner_id=v_user) then
    raise exception 'IMPORT_TARGET_NOT_VISIBLE';
  end if;
  insert into internal.legacy_import_receipts(owner_id,device_id,record_id,record_kind,
    source_sha256,played_at,round_id,bag_item_id)
    values (v_user,p_device_id,p_record_id,p_record_kind,p_source_sha256,p_played_at,
      case when p_record_kind='app_bag_disc' then null else p_target_id end,
      case when p_record_kind='app_bag_disc' then p_target_id else null end);
  if p_played_at is not null then
    update public.rounds set started_at=p_played_at where id=p_target_id and owner_id=v_user;
  end if;
  return jsonb_build_object('record_id',p_record_id,'target_id',p_target_id,'replayed',false);
end;
$$;

create function public.list_legacy_import_receipts_v1(p_device_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('record_id',record_id,'record_kind',record_kind,
    'source_sha256',source_sha256,'played_at',played_at,'target_id',coalesce(round_id,bag_item_id),
    'acknowledged_at',acknowledged_at) order by acknowledged_at,record_id),'[]'::jsonb)
  from internal.legacy_import_receipts where owner_id=(select auth.uid()) and device_id=p_device_id;
$$;

create function public.export_account_v1()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when (select auth.uid()) is null then null else jsonb_build_object(
    'user_id',(select auth.uid()),
    'profile',(select to_jsonb(p) from public.profiles p where p.user_id=(select auth.uid())),
    'rounds',coalesce((select jsonb_agg(to_jsonb(r) order by r.started_at,r.id)
      from public.rounds r where r.owner_id=(select auth.uid())),'[]'::jsonb),
    'participants',coalesce((select jsonb_agg(to_jsonb(p) order by p.round_id,p.id)
      from public.round_participants p join public.rounds r on r.id=p.round_id
      where r.owner_id=(select auth.uid())),'[]'::jsonb),
    'hole_snapshots',coalesce((select jsonb_agg(to_jsonb(h) order by h.round_id,h.hole_number)
      from public.round_hole_snapshots h join public.rounds r on r.id=h.round_id
      where r.owner_id=(select auth.uid())),'[]'::jsonb),
    'scores',coalesce((select jsonb_agg(to_jsonb(s) order by s.round_id,s.snapshot_hole_id)
      from public.hole_scores s join public.rounds r on r.id=s.round_id
      where r.owner_id=(select auth.uid())),'[]'::jsonb),
    'bag_items',coalesce((select jsonb_agg(to_jsonb(b) order by b.id)
      from public.bag_items b where b.owner_id=(select auth.uid())),'[]'::jsonb),
    'import_receipts',coalesce((select jsonb_agg(to_jsonb(i) order by i.device_id,i.record_id)
      from internal.legacy_import_receipts i where i.owner_id=(select auth.uid())),'[]'::jsonb)
  ) end;
$$;

create function public.delete_account_v1(p_confirmation text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := (select auth.uid());
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_confirmation <> 'DELETE MY BIRDIE FINDER ACCOUNT' then raise exception 'CONFIRMATION_REQUIRED'; end if;
  delete from auth.users where id=v_user;
  return jsonb_build_object('deleted',true,'user_id',v_user);
end;
$$;

revoke all on function public.ack_legacy_import_v1(uuid,uuid,text,text,uuid,timestamptz),
  public.list_legacy_import_receipts_v1(uuid),public.export_account_v1(),
  public.delete_account_v1(text) from public,anon;
grant execute on function public.ack_legacy_import_v1(uuid,uuid,text,text,uuid,timestamptz),
  public.list_legacy_import_receipts_v1(uuid),public.export_account_v1(),
  public.delete_account_v1(text) to authenticated;
