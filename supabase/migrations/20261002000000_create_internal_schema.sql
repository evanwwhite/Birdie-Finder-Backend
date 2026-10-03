-- Private home for staged imports and other backend-only objects.
create schema if not exists internal;
revoke all on schema internal from public, anon, authenticated;
