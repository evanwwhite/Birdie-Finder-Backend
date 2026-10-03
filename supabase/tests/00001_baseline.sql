begin;
select plan(2);

select has_schema('internal', 'backend-only schema exists');
select ok(not has_schema_privilege('anon', 'internal', 'USAGE'), 'anonymous clients cannot use internal schema');

select * from finish();
rollback;
