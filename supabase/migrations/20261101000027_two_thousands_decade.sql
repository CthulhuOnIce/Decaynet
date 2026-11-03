-- =============================================================================
-- Decaynet :: 0027 "2000s" is a decade
--
-- The date parser read "2000s" as the century 2000–2099 (like "1900s"), so a
-- fact entered as ending in the 2000s ran until 2100 and stayed current: an
-- occupancy "1965 – 2000s" still showed as occupied in 2026. The app now reads
-- "2000s" as the decade 2000–2009 and shows centuries as "21st century".
--
-- This turns the dates already stored that way (century precision on 2000) into
-- the decade they were meant to be. A date deliberately entered as "21st
-- century" is converted too; re-enter it as "21st century" if that was meant.
-- =============================================================================

do $$
declare
  t text;
begin
  update public.entities set exists_from_precision = 'decade'
   where exists_from = '2000-01-01' and exists_from_precision = 'century';
  update public.entities set exists_to_precision = 'decade'
   where exists_to = '2000-01-01' and exists_to_precision = 'century';
  update public.sources set published_precision = 'decade'
   where published_on = '2000-01-01' and published_precision = 'century';
  foreach t in array array['entity_names', 'entity_states', 'entity_geometries', 'entity_attributes',
                           'addresses', 'relations', 'entity_tags'] loop
    execute format('update public.%I set valid_from_precision = ''decade''
                     where valid_from = ''2000-01-01'' and valid_from_precision = ''century''', t);
    execute format('update public.%I set valid_to_precision = ''decade''
                     where valid_to = ''2000-01-01'' and valid_to_precision = ''century''', t);
  end loop;
end $$;
