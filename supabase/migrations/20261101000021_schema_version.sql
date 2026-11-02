-- =============================================================================
-- Decaynet :: 0021 schema version
--
-- The app and the database are upgraded separately (the app image, and the
-- one-shot migrate step). When the app is newer than the database, new pages
-- fail on functions that don't exist yet. schema_version() reports the newest
-- migration applied, so the app can tell admins to run the migrate step
-- instead of failing with an internal error.
-- =============================================================================

create or replace function public.schema_version()
returns text
language plpgsql stable security definer set search_path = public as $$
begin
  -- recorded by the migrate runner and by the Supabase CLI alike
  return (select max(version) from supabase_migrations.schema_migrations);
exception when undefined_table or invalid_schema_name then
  return null;   -- applied by hand: unknown
end;
$$;

grant execute on function public.schema_version() to anon, authenticated;
