begin;
select no_plan();
insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at) values
 ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','00000000-0000-0000-0000-000000000000','authenticated','authenticated','bag-owner@example.invalid','',now()),
 ('bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb','00000000-0000-0000-0000-000000000000','authenticated','authenticated','bag-other@example.invalid','',now());
insert into public.disc_molds(id,name,manufacturer,data_version,attribution,published) values
 ('cccccccc-3333-4333-8333-cccccccccccc','Test Mold','Test Maker','synthetic-2026-10-02-v1','Fixture',true);

set local role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',true);
insert into public.bag_items(id,owner_id,disc_mold_id) values
 ('dddddddd-4444-4444-8444-dddddddddddd','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','cccccccc-3333-4333-8333-cccccccccccc');
select is((select count(*)::integer from public.bag_items),1,'owner sees their bag item');
select is((public.ack_legacy_import_v1('eeeeeeee-5555-4555-8555-eeeeeeeeeeee',
 'ffffffff-6666-4666-8666-ffffffffffff','app_bag_disc',repeat('a',64),
 'dddddddd-4444-4444-8444-dddddddddddd')->>'replayed')::boolean,false,
 'first receipt acknowledges a visible bag item');
select is((public.ack_legacy_import_v1('eeeeeeee-5555-4555-8555-eeeeeeeeeeee',
 'ffffffff-6666-4666-8666-ffffffffffff','app_bag_disc',repeat('a',64),
 'dddddddd-4444-4444-8444-dddddddddddd')->>'replayed')::boolean,true,
 'receipt replay is idempotent');
select is(jsonb_array_length(public.list_legacy_import_receipts_v1('eeeeeeee-5555-4555-8555-eeeeeeeeeeee')),
 1,'one account and device receipt appears');
select is(jsonb_array_length(public.export_account_v1()->'bag_items'),1,'account export includes bag');
select is(jsonb_array_length(public.export_account_v1()->'import_receipts'),1,
 'account export includes import manifest receipts');
insert into public.bag_items(id,owner_id,disc_mold_id) values
 ('dddddddd-4444-4444-8444-ddddddddddde','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','cccccccc-3333-4333-8333-cccccccccccc');
select is((select count(*)::integer from public.bag_items),2,
 'two physical discs of the same mold remain distinct bag items');
select is((public.ack_legacy_import_v1('eeeeeeee-5555-4555-8555-eeeeeeeeeeee',
 'ffffffff-6666-4666-8666-fffffffffffe','app_bag_disc',repeat('a',64),
 'dddddddd-4444-4444-8444-ddddddddddde')->>'replayed')::boolean,false,
 'second same-mold disc keeps a separate import receipt');
select is((public.create_solo_round_v1('{"round_id":"11111111-aaaa-4aaa-8aaa-111111111111","participant_id":"22222222-aaaa-4aaa-8aaa-222222222222","course_id":"11111111-1111-4111-8111-111111111111","layout_version_id":"44444444-4444-4444-8444-444444444444","custom_layout":null}')#>>'{data,id}'),
 '11111111-aaaa-4aaa-8aaa-111111111111','first identical-looking legacy round saves');
select is((public.create_solo_round_v1('{"round_id":"11111111-bbbb-4bbb-8bbb-111111111111","participant_id":"22222222-bbbb-4bbb-8bbb-222222222222","course_id":"11111111-1111-4111-8111-111111111111","layout_version_id":"44444444-4444-4444-8444-444444444444","custom_layout":null}')#>>'{data,id}'),
 '11111111-bbbb-4bbb-8bbb-111111111111','second identical-looking legacy round saves separately');
select is((public.ack_legacy_import_v1('eeeeeeee-5555-4555-8555-eeeeeeeeeeee',
 '33333333-aaaa-4aaa-8aaa-333333333333','app_round',repeat('b',64),
 '11111111-aaaa-4aaa-8aaa-111111111111','2026-09-20T12:00:00Z')->>'replayed')::boolean,false,
 'first round receives its own import receipt');
select is((select started_at from public.rounds where id='11111111-aaaa-4aaa-8aaa-111111111111'),
 '2026-09-20T12:00:00Z'::timestamptz,'import preserves the known historical date');
select is((public.ack_legacy_import_v1('eeeeeeee-5555-4555-8555-eeeeeeeeeeee',
 '33333333-bbbb-4bbb-8bbb-333333333333','app_round',repeat('b',64),
 '11111111-bbbb-4bbb-8bbb-111111111111')->>'replayed')::boolean,false,
 'matching content can have a separate manifest record and receipt');
select is((select count(*)::integer from public.rounds where owner_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'),
 2,'two identical-looking rounds remain distinct');
do $$ begin perform public.ack_legacy_import_v1('eeeeeeee-5555-4555-8555-eeeeeeeeeeee',
 '33333333-aaaa-4aaa-8aaa-333333333333','app_round',repeat('c',64),
 '11111111-aaaa-4aaa-8aaa-111111111111');
 exception when others then perform set_config('test.changed_receipt_error',SQLERRM,true); end $$;
select is(current_setting('test.changed_receipt_error'),'IMPORT_RECEIPT_CONFLICT',
 'a replay with changed source content is rejected');

select set_config('request.jwt.claim.sub','bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb',true);
select is((select count(*)::integer from public.bag_items),0,'other account cannot read bag');
select is(jsonb_array_length(public.export_account_v1()->'bag_items'),0,'other account export has no owner bag');
select is(jsonb_array_length(public.list_legacy_import_receipts_v1('eeeeeeee-5555-4555-8555-eeeeeeeeeeee')),
 0,'other account cannot read import receipt');
do $$ begin
 perform public.ack_legacy_import_v1('eeeeeeee-5555-4555-8555-eeeeeeeeeeee',
 'ffffffff-6666-4666-8666-ffffffffffff','app_bag_disc',repeat('a',64),
 'dddddddd-4444-4444-8444-dddddddddddd');
exception when others then perform set_config('test.foreign_receipt_error',SQLERRM,true); end $$;
select is(current_setting('test.foreign_receipt_error'),'IMPORT_TARGET_NOT_VISIBLE',
 'other account cannot claim owner bag item');
do $$ begin perform public.delete_account_v1('wrong');
 exception when others then perform set_config('test.delete_error',SQLERRM,true); end $$;
select is(current_setting('test.delete_error'),'CONFIRMATION_REQUIRED','deletion requires exact phrase');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',true);
select is((public.delete_account_v1('DELETE MY BIRDIE FINDER ACCOUNT')->>'deleted')::boolean,
 true,'confirmed owner deletion completes');
reset role;
select is((select count(*)::integer from auth.users where id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'),
 0,'deleted account row is gone');
select is((select count(*)::integer from public.bag_items where owner_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'),
 0,'deleted account bag cascades');
select is((select count(*)::integer from internal.legacy_import_receipts where owner_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'),
 0,'deleted account receipts cascade');
select is((select count(*)::integer from auth.users where id='bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'),
 1,'unrelated account survives deletion');

set local role anon;
select ok(not has_table_privilege(current_user,'public.bag_items','SELECT'),
 'anonymous client cannot read bag');
select ok(not has_function_privilege(current_user,'public.export_account_v1()','EXECUTE'),
 'anonymous client cannot export account');
reset role;

select * from finish();
rollback;
