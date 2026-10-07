-- Minimal stand-ins for what a Supabase project provides, so the migrations
-- and tests run against plain Postgres (CI and scripts/test-db.sh).
-- Never apply this to a real Supabase project.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create table auth.users (
  id                 uuid primary key,
  phone              text,                 -- set by phone OTP sign-in, digits only
  raw_user_meta_data jsonb not null default '{}'
);

-- Supabase installs extensions such as pgcrypto into this schema.
create schema extensions;
create extension pgcrypto with schema extensions;

-- Supabase's auth.uid(): the JWT "sub" claim PostgREST puts in request.jwt.claims.
create function auth.uid() returns uuid
language sql stable
as $$ select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid $$;

grant usage on schema auth   to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- Supabase's default privileges for objects created in public.
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
