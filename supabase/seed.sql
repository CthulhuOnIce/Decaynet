-- =============================================================================
-- Decaynet seed: a starter set of Gary, Indiana entities.
--
-- ⚠ Coordinates are APPROXIMATE placeholders on an idealized street grid and
--   are flagged confidence = 'approximate'. Dates are drawn from commonly cited
--   public histories and flagged where uncertain. Every row here is meant to be
--   verified and cited by contributors; the maintenance page will nag about it.
-- =============================================================================

-- Helpers (session-local)
create function pg_temp.e(p_slug text) returns uuid language sql stable as $$
  select id from public.entities where slug = p_slug
$$;
create function pg_temp.d(p text) returns date language sql immutable as $$ select p::date $$;
create function pg_temp.pt(lon float8, lat float8) returns extensions.geometry language sql immutable as $$
  select extensions.st_setsrid(extensions.st_makepoint(lon, lat), 4326)
$$;
create function pg_temp.ln(lon1 float8, lat1 float8, lon2 float8, lat2 float8) returns extensions.geometry
language sql immutable as $$
  select extensions.st_setsrid(extensions.st_makeline(extensions.st_makepoint(lon1, lat1),
                                                      extensions.st_makepoint(lon2, lat2)), 4326)
$$;
-- Rectangle footprint centred on a point, w x h metres
create function pg_temp.fp(lon float8, lat float8, w_m float8, h_m float8) returns extensions.geometry
language sql immutable as $$
  select extensions.st_makeenvelope(
    lon - (w_m / 2) / (111320 * cos(radians(lat))), lat - (h_m / 2) / 110574,
    lon + (w_m / 2) / (111320 * cos(radians(lat))), lat + (h_m / 2) / 110574, 4326)
$$;
create function pg_temp.box(w float8, s float8, e float8, n float8) returns extensions.geometry
language sql immutable as $$ select extensions.st_makeenvelope(w, s, e, n, 4326) $$;

-- -----------------------------------------------------------------------------
-- Sources
-- -----------------------------------------------------------------------------
insert into public.sources (id, title, kind, url, publisher, notes) values
  ('00000000-0000-4000-8000-000000000001', 'Gary, Indiana', 'website',
   'https://en.wikipedia.org/wiki/Gary,_Indiana', 'Wikipedia',
   'Overview reference used for seed data. Replace with primary sources where possible.'),
  ('00000000-0000-4000-8000-000000000002', 'Steel strike of 1919', 'website',
   'https://en.wikipedia.org/wiki/Steel_strike_of_1919', 'Wikipedia', null),
  ('00000000-0000-4000-8000-000000000003', 'Richard G. Hatcher', 'website',
   'https://en.wikipedia.org/wiki/Richard_G._Hatcher', 'Wikipedia', null);
insert into public.sources (id, title, kind, repository, notes) values
  ('00000000-0000-4000-8000-000000000004', 'Calumet Regional Archives', 'archive',
   'Indiana University Northwest, Gary, Indiana',
   'Primary repository for Gary city records, photographs, and oral histories. Cite collection + box/folder in source_detail.');

-- -----------------------------------------------------------------------------
-- Entities
-- -----------------------------------------------------------------------------
insert into public.entities (kind, slug, name, summary, exists_from, exists_from_precision, exists_to, exists_to_precision, lifespan_confidence) values
  -- districts
  ('district', 'downtown-gary', 'Downtown Gary', 'The original commercial core laid out by the Gary Land Company along Broadway.', '1906-01-01', 'year', null, 'year', 'probable'),
  ('district', 'miller-beach', 'Miller Beach', 'Lakefront neighborhood on the east side; older than Gary itself and annexed later.', null, 'year', null, 'year', 'probable'),
  ('district', 'emerson', 'Emerson', 'East-side neighborhood around Emerson School.', null, 'year', null, 'year', 'probable'),
  -- streets
  ('street', 'broadway', 'Broadway', 'The north–south spine of Gary, running from the steel mill gates south through downtown.', '1906-01-01', 'year', null, 'year', 'probable'),
  ('street', '5th-avenue', '5th Avenue', 'Principal east–west avenue through downtown.', '1906-01-01', 'year', null, 'year', 'probable'),
  ('street', '6th-avenue', '6th Avenue', null, '1906-01-01', 'year', null, 'year', 'approximate'),
  ('street', '7th-avenue', '7th Avenue', null, '1906-01-01', 'year', null, 'year', 'approximate'),
  ('street', 'washington-street', 'Washington Street', 'North–south street one block west of Broadway.', '1906-01-01', 'year', null, 'year', 'approximate'),
  ('street', 'jackson-street', 'Jackson Street', null, null, 'year', null, 'year', 'approximate'),
  -- buildings & sites
  ('building', 'gary-land-company-building', 'Gary Land Company Building', 'The first building in Gary, a small frame office of the company that platted the city.', '1906-01-01', 'year', null, 'year', 'probable'),
  ('building', 'gary-union-station', 'Gary Union Station', 'Beaux-Arts railroad station of poured concrete beside the elevated tracks at the north end of Broadway.', '1910-01-01', 'year', null, 'year', 'probable'),
  ('building', 'emerson-school', 'Emerson School', 'Early school of the Gary "work-study-play" system.', '1909-01-01', 'year', null, 'year', 'probable'),
  ('building', 'palace-theater', 'Palace Theater', 'Downtown movie palace on Broadway.', '1925-01-01', 'year', null, 'year', 'probable'),
  ('building', 'city-methodist-church', 'City Methodist Church', 'Gothic Revival church whose ruin became the best-known image of Gary''s decline.', '1926-01-01', 'year', null, 'year', 'probable'),
  ('building', 'hotel-gary', 'Hotel Gary', 'Downtown hotel at Broadway and 6th Avenue, later converted to senior housing.', '1927-01-01', 'year', null, 'year', 'probable'),
  ('building', 'gary-city-hall', 'Gary City Hall', 'Neoclassical city hall facing Broadway at Gateway Park.', '1928-01-01', 'year', null, 'year', 'probable'),
  ('building', 'genesis-convention-center', 'Genesis Convention Center', 'Downtown convention and event center.', '1981-01-01', 'year', null, 'year', 'probable'),
  ('building', 'jackson-family-home', 'Jackson Family Home', 'Two-bedroom house at 2300 Jackson Street where the Jackson family lived.', null, 'year', null, 'year', 'probable'),
  ('site', 'gary-bathing-beach-aquatorium', 'Gary Bathing Beach Aquatorium', 'Lakefront bathhouse in Marquette Park, later restored with a memorial to Octave Chanute.', '1921-01-01', 'year', null, 'year', 'probable'),
  ('site', 'gary-works', 'U.S. Steel Gary Works', 'The lakefront steel mill the city was built to serve.', '1908-01-01', 'year', null, 'year', 'probable'),
  -- organizations
  -- water
  ('water', 'lake-michigan', 'Lake Michigan', 'The lake. Its Gary shoreline moved north as mill land was filled in.', null, 'year', null, 'year', 'confirmed'),
  ('water', 'grand-calumet-river', 'Grand Calumet River', 'River between the mill and the city; its channel was altered for industry.', null, 'year', null, 'year', 'probable'),
  ('organization', 'us-steel', 'United States Steel Corporation', 'Steel company that founded Gary as a company town for Gary Works.', '1901-01-01', 'year', null, 'year', 'confirmed'),
  ('organization', 'gary-land-company', 'Gary Land Company', 'U.S. Steel subsidiary that platted and sold the original town.', '1906-01-01', 'year', null, 'year', 'probable'),
  ('organization', 'city-of-gary', 'City of Gary', 'Municipal government. Incorporated as a town in 1906 and as a city in 1909.', '1906-01-01', 'year', null, 'year', 'probable'),
  ('organization', 'gary-public-schools', 'Gary Public Schools', 'Public school system, nationally known for the Wirt "platoon" plan.', '1906-01-01', 'year', null, 'year', 'approximate'),
  ('organization', 'city-methodist-congregation', 'City Methodist congregation', 'Methodist congregation that built and occupied City Methodist Church.', null, 'year', '1975-01-01', 'year', 'probable'),
  -- people
  ('person', 'elbert-h-gary', 'Elbert H. Gary', 'Chairman of U.S. Steel and the city''s namesake.', '1846-10-08', 'day', '1927-08-15', 'day', 'probable'),
  ('person', 'william-a-wirt', 'William A. Wirt', 'Superintendent of Gary schools; creator of the work-study-play system.', '1874-01-01', 'year', '1938-01-01', 'year', 'probable'),
  ('person', 'richard-g-hatcher', 'Richard G. Hatcher', 'Mayor of Gary 1968–1987; among the first Black mayors of a large U.S. city.', '1933-07-10', 'day', '2019-12-13', 'day', 'probable'),
  ('person', 'michael-jackson', 'Michael Jackson', 'Singer, born in Gary; grew up at 2300 Jackson Street.', '1958-08-29', 'day', '2009-06-25', 'day', 'confirmed'),
  ('person', 'octave-chanute', 'Octave Chanute', 'Engineer and aviation pioneer who flew gliders from the Miller dunes.', '1832-02-18', 'day', '1910-11-23', 'day', 'probable'),
  -- events
  ('event', 'chanute-glider-experiments', 'Chanute glider experiments in the Miller dunes', 'Manned glider trials on the dunes east of the future city.', '1896-01-01', 'year', '1896-01-01', 'year', 'probable'),
  ('event', 'founding-of-gary', 'Founding of Gary', 'U.S. Steel begins building a mill town on the dunes at the southern tip of Lake Michigan.', '1906-01-01', 'year', '1906-01-01', 'year', 'probable'),
  ('event', 'gary-incorporated-as-city', 'Gary incorporated as a city', null, '1909-01-01', 'year', '1909-01-01', 'year', 'probable'),
  ('event', 'steel-strike-of-1919', 'Steel strike of 1919', 'Nationwide steel strike; Gary was placed under federal troops.', '1919-09-22', 'day', '1920-01-08', 'day', 'probable'),
  ('event', 'hatcher-elected-mayor', 'Richard Hatcher elected mayor', null, '1967-11-07', 'day', '1967-11-07', 'day', 'probable'),
  ('event', 'city-methodist-closes', 'City Methodist Church closes', 'The dwindling congregation leaves the building.', '1975-01-01', 'year', '1975-01-01', 'year', 'probable'),
  ('event', 'miss-usa-in-gary', 'Miss USA pageants at the Genesis Center', 'The pageant is broadcast from Gary two years running.', '2001-01-01', 'year', '2002-01-01', 'year', 'probable'),
  ('event', 'emerson-school-closes', 'Emerson School closes', null, '2008-01-01', 'year', '2008-01-01', 'year', 'probable');

insert into public.event_details (entity_id, event_type)
select pg_temp.e(s), t from (values
  ('chanute-glider-experiments', 'other'),
  ('founding-of-gary', 'founding'),
  ('gary-incorporated-as-city', 'founding'),
  ('steel-strike-of-1919', 'labor'),
  ('hatcher-elected-mayor', 'election'),
  ('city-methodist-closes', 'closing'),
  ('miss-usa-in-gary', 'other'),
  ('emerson-school-closes', 'closing')
) v (s, t);

-- -----------------------------------------------------------------------------
-- Geometries (approximate!)
-- -----------------------------------------------------------------------------
insert into public.entity_geometries (entity_id, role, geom, valid_from, valid_to, confidence, note) values
  (pg_temp.e('downtown-gary'),   'boundary', pg_temp.box(-87.3435, 41.5945, -87.3330, 41.6070), '1906-01-01', null, 'approximate', 'Rough outline for demonstration.'),
  (pg_temp.e('miller-beach'),    'boundary', pg_temp.box(-87.2760, 41.5960, -87.2400, 41.6230), null, null, 'approximate', 'Rough outline for demonstration.'),
  (pg_temp.e('emerson'),         'boundary', pg_temp.box(-87.3330, 41.5900, -87.3200, 41.6020), null, null, 'approximate', 'Rough outline for demonstration.'),
  -- Broadway: illustrative growth of the platted grid southward
  (pg_temp.e('broadway'),        'centerline', pg_temp.ln(-87.33718, 41.6070, -87.33718, 41.5850), '1906-01-01', '1919-01-01', 'speculative', 'Illustrative extent only; verify against plat/Sanborn maps.'),
  (pg_temp.e('broadway'),        'centerline', pg_temp.ln(-87.33718, 41.6070, -87.33718, 41.5500), '1920-01-01', null, 'approximate', null),
  (pg_temp.e('5th-avenue'),      'centerline', pg_temp.ln(-87.3900, 41.60205, -87.2800, 41.60205), '1906-01-01', null, 'approximate', null),
  (pg_temp.e('6th-avenue'),      'centerline', pg_temp.ln(-87.3520, 41.6002, -87.3150, 41.6002), '1906-01-01', null, 'approximate', null),
  (pg_temp.e('7th-avenue'),      'centerline', pg_temp.ln(-87.3520, 41.59843, -87.3150, 41.59843), '1906-01-01', null, 'approximate', null),
  (pg_temp.e('washington-street'),'centerline', pg_temp.ln(-87.33843, 41.6060, -87.33843, 41.5800), '1906-01-01', null, 'approximate', null),
  (pg_temp.e('jackson-street'),  'centerline', pg_temp.ln(-87.3445, 41.6000, -87.3445, 41.5650), null, null, 'approximate', null),
  (pg_temp.e('gary-land-company-building'), 'footprint', pg_temp.fp(-87.3369, 41.6046, 8, 6), null, null, 'approximate', 'Current location in Gateway Park. The building was relocated several times; earlier positions are not yet mapped.'),
  (pg_temp.e('gary-union-station'),   'footprint', pg_temp.fp(-87.3380, 41.6062, 60, 26), '1910-01-01', null, 'approximate', null),
  (pg_temp.e('emerson-school'),       'footprint', pg_temp.fp(-87.3284, 41.5987, 85, 55), '1909-01-01', null, 'approximate', null),
  (pg_temp.e('palace-theater'),       'footprint', pg_temp.fp(-87.33745, 41.5976, 30, 55), '1925-01-01', null, 'approximate', null),
  (pg_temp.e('city-methodist-church'),'footprint', pg_temp.fp(-87.3381, 41.6007, 45, 60), '1926-01-01', null, 'approximate', null),
  (pg_temp.e('hotel-gary'),           'footprint', pg_temp.fp(-87.33745, 41.60055, 40, 42), '1927-01-01', null, 'approximate', null),
  (pg_temp.e('gary-city-hall'),       'footprint', pg_temp.fp(-87.33745, 41.6030, 60, 40), '1928-01-01', null, 'approximate', null),
  (pg_temp.e('genesis-convention-center'), 'footprint', pg_temp.fp(-87.3404, 41.6028, 110, 85), '1981-01-01', null, 'approximate', null),
  (pg_temp.e('jackson-family-home'),  'footprint', pg_temp.fp(-87.3447, 41.5745, 8, 11), null, null, 'approximate', null),
  (pg_temp.e('gary-bathing-beach-aquatorium'), 'footprint', pg_temp.fp(-87.2585, 41.6195, 60, 22), '1921-01-01', null, 'approximate', null),
  (pg_temp.e('gary-works'),           'shape', pg_temp.box(-87.3800, 41.6090, -87.3000, 41.6250), '1908-01-01', null, 'approximate', 'Very rough block for the mill complex.');

-- Water: present-day approximations. Add earlier shorelines/channels as separate dated geometries.
insert into public.entity_geometries (entity_id, role, geom, valid_from, confidence, note) values
  (pg_temp.e('lake-michigan'), 'shape',
   extensions.st_geomfromtext('POLYGON((-87.45 41.640,-87.38 41.632,-87.30 41.628,-87.26 41.6215,-87.20 41.625,-87.20 41.700,-87.45 41.700,-87.45 41.640))', 4326),
   null, 'approximate', 'Rough present-day shoreline. Much of Gary Works sits on land filled into the lake after 1906; map the earlier shoreline as a geometry valid before then.'),
  (pg_temp.e('grand-calumet-river'), 'centerline',
   extensions.st_geomfromtext('LINESTRING(-87.40 41.6105,-87.34 41.6085,-87.29 41.6075)', 4326),
   null, 'speculative', 'Placeholder course. Trace the real channel (and its pre-1906 course) from historical maps.');

-- Spaces inside buildings: building > space > tenant
insert into public.entities (kind, slug, name, summary, exists_from, exists_from_precision, lifespan_confidence) values
  ('space', 'city-methodist-church-sanctuary', 'Sanctuary', 'Main worship space of City Methodist Church.', '1926-01-01', 'year', 'probable'),
  ('space', 'city-methodist-church-community-wing', 'Education & community wing', 'Classrooms, offices and an auditorium for civic use.', '1926-01-01', 'year', 'probable'),
  ('space', 'palace-theater-auditorium', 'Auditorium', null, '1925-01-01', 'year', 'probable'),
  ('space', 'palace-theater-lobby', 'Lobby', 'Street-front lobby facing Broadway.', '1925-01-01', 'year', 'approximate');

insert into public.entity_geometries (entity_id, role, geom, valid_from, confidence, note) values
  (pg_temp.e('city-methodist-church-sanctuary'),      'footprint', pg_temp.fp(-87.3381, 41.60084, 43, 28), '1926-01-01', 'speculative', 'Schematic split of the footprint; trace from a Sanborn sheet.'),
  (pg_temp.e('city-methodist-church-community-wing'), 'footprint', pg_temp.fp(-87.3381, 41.60054, 43, 28), '1926-01-01', 'speculative', 'Schematic split of the footprint; trace from a Sanborn sheet.'),
  (pg_temp.e('palace-theater-auditorium'),            'footprint', pg_temp.fp(-87.33752, 41.5976, 18, 52), '1925-01-01', 'speculative', 'Schematic.'),
  (pg_temp.e('palace-theater-lobby'),                 'footprint', pg_temp.fp(-87.33733, 41.5976, 7, 20), '1925-01-01', 'speculative', 'Schematic.');

insert into public.relations (subject_id, predicate, object_id, confidence) values
  (pg_temp.e('city-methodist-church-sanctuary'), 'part_of', pg_temp.e('city-methodist-church'), 'probable'),
  (pg_temp.e('city-methodist-church-community-wing'), 'part_of', pg_temp.e('city-methodist-church'), 'probable'),
  (pg_temp.e('palace-theater-auditorium'), 'part_of', pg_temp.e('palace-theater'), 'probable'),
  (pg_temp.e('palace-theater-lobby'), 'part_of', pg_temp.e('palace-theater'), 'probable');

insert into public.relations (subject_id, predicate, object_id, valid_from, valid_to, confidence) values
  (pg_temp.e('city-methodist-congregation'), 'occupies', pg_temp.e('city-methodist-church-sanctuary'), '1926-01-01', '1975-01-01', 'probable'),
  (pg_temp.e('city-methodist-congregation'), 'occupies', pg_temp.e('city-methodist-church-community-wing'), '1926-01-01', '1975-01-01', 'probable');

insert into public.entity_attributes (entity_id, key, value) values
  (pg_temp.e('city-methodist-church-sanctuary'), 'floor', '1'),
  (pg_temp.e('city-methodist-church-community-wing'), 'floor', '1'),
  (pg_temp.e('palace-theater-auditorium'), 'floor', '1'),
  (pg_temp.e('palace-theater-lobby'), 'floor', '1');

-- Event / media point (Chanute had no structure to attach to)
insert into public.entity_geometries (entity_id, role, geom, valid_from, confidence, note) values
  (pg_temp.e('chanute-glider-experiments'), 'point', pg_temp.pt(-87.2560, 41.6170), '1896-01-01', 'speculative', 'General dune area only.');

-- -----------------------------------------------------------------------------
-- Names over time
-- -----------------------------------------------------------------------------
insert into public.entity_names (entity_id, name, name_type, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, note) values
  (pg_temp.e('hotel-gary'), 'Hotel Gary', 'official', '1927-01-01', 'year', '1979-01-01', 'decade', 'approximate', 'End of hotel use needs a source.'),
  (pg_temp.e('hotel-gary'), 'Genesis Towers', 'official', '1980-01-01', 'decade', null, 'year', 'approximate', 'Senior apartments; conversion date needs a source.'),
  (pg_temp.e('city-methodist-church'), 'First Methodist Episcopal Church', 'historic', '1926-01-01', 'year', '1939-01-01', 'year', 'speculative', 'Pre-1939 denominational name; verify.'),
  (pg_temp.e('city-methodist-church'), 'City Methodist Church', 'common', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-union-station'), 'Union Station', 'common', '1910-01-01', 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-works'), 'Gary Works', 'common', '1908-01-01', 'year', null, 'year', 'confirmed', null);

-- -----------------------------------------------------------------------------
-- Lifecycle states
-- -----------------------------------------------------------------------------
insert into public.entity_states (entity_id, status, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, note) values
  (pg_temp.e('gary-union-station'), 'active',     '1910-01-01', 'year',   '1950-01-01', 'decade', 'approximate', 'Passenger service ended sometime in the 1950s.'),
  (pg_temp.e('gary-union-station'), 'abandoned',  '1950-01-01', 'decade', null, 'year', 'approximate', null),
  (pg_temp.e('emerson-school'),     'active',     '1909-01-01', 'year',   '2008-01-01', 'year', 'probable', null),
  (pg_temp.e('emerson-school'),     'closed',     '2008-01-01', 'year',   null, 'year', 'probable', null),
  (pg_temp.e('palace-theater'),     'active',     '1925-01-01', 'year',   '1972-01-01', 'year', 'probable', null),
  (pg_temp.e('palace-theater'),     'abandoned',  '1972-01-01', 'year',   null, 'year', 'probable', null),
  (pg_temp.e('city-methodist-church'), 'active',  '1926-01-01', 'year',   '1975-01-01', 'year', 'probable', null),
  (pg_temp.e('city-methodist-church'), 'abandoned', '1975-01-01', 'year', '1989-01-01', 'decade', 'approximate', null),
  (pg_temp.e('city-methodist-church'), 'ruin',    '1990-01-01', 'decade', null, 'year', 'approximate', 'Roof and interior failure; date range needs a source.'),
  (pg_temp.e('hotel-gary'),         'active',     '1927-01-01', 'year',   '1979-01-01', 'decade', 'approximate', null),
  (pg_temp.e('hotel-gary'),         'repurposed', '1980-01-01', 'decade', null, 'year', 'approximate', 'Senior housing.'),
  (pg_temp.e('gary-city-hall'),     'active',     '1928-01-01', 'year',   null, 'year', 'probable', null),
  (pg_temp.e('genesis-convention-center'), 'active', '1981-01-01', 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-bathing-beach-aquatorium'), 'active', '1921-01-01', 'year', '1989-01-01', 'decade', 'approximate', null),
  (pg_temp.e('gary-bathing-beach-aquatorium'), 'restored', '1990-01-01', 'decade', null, 'year', 'approximate', 'Community-led restoration.'),
  (pg_temp.e('gary-works'),         'active',     '1908-01-01', 'year',   null, 'year', 'probable', null),
  (pg_temp.e('gary-land-company-building'), 'restored', null, 'year', null, 'year', 'approximate', 'Preserved as the city''s first building.');

-- -----------------------------------------------------------------------------
-- Addresses (street names resolve through time automatically)
-- -----------------------------------------------------------------------------
insert into public.addresses (entity_id, street_id, house_number, raw_address, valid_from, confidence) values
  (pg_temp.e('city-methodist-church'), pg_temp.e('washington-street'), '577', '577 Washington St', '1926-01-01', 'probable'),
  (pg_temp.e('palace-theater'),        pg_temp.e('broadway'),          '791', '791 Broadway', '1925-01-01', 'probable'),
  (pg_temp.e('gary-city-hall'),        pg_temp.e('broadway'),          '401', '401 Broadway', '1928-01-01', 'probable'),
  (pg_temp.e('jackson-family-home'),   pg_temp.e('jackson-street'),    '2300', '2300 Jackson St', null, 'probable'),
  (pg_temp.e('emerson-school'),        pg_temp.e('7th-avenue'),        '716 E.', '716 E. 7th Ave', '1909-01-01', 'approximate');

-- -----------------------------------------------------------------------------
-- Attributes
-- -----------------------------------------------------------------------------
insert into public.entity_attributes (entity_id, key, value, valid_from, confidence, note) values
  (pg_temp.e('city-methodist-church'), 'architectural_style', '"Gothic Revival"', '1926-01-01', 'probable', null),
  (pg_temp.e('city-methodist-church'), 'construction_cost', '1000000', '1926-01-01', 'approximate', 'Commonly cited figure (~$1 million in 1920s dollars).'),
  (pg_temp.e('gary-union-station'), 'architectural_style', '"Beaux-Arts"', '1910-01-01', 'probable', null),
  (pg_temp.e('gary-union-station'), 'material', '"Reinforced concrete"', '1910-01-01', 'probable', null),
  (pg_temp.e('city-of-gary'), 'website', '"https://gary.gov"', null, 'probable', null),
  (pg_temp.e('gary-works'), 'industry', '"Steel"', null, 'confirmed', null),
  (pg_temp.e('us-steel'), 'industry', '"Steel"', null, 'confirmed', null),
  (pg_temp.e('richard-g-hatcher'), 'occupation', '"Lawyer, politician"', null, 'probable', null),
  (pg_temp.e('william-a-wirt'), 'occupation', '"School superintendent"', '1907-01-01', 'probable', null);

-- -----------------------------------------------------------------------------
-- Relations
-- -----------------------------------------------------------------------------
insert into public.relations (subject_id, predicate, object_id, qualifiers, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id) values
  (pg_temp.e('city-of-gary'), 'named_after', pg_temp.e('elbert-h-gary'), '{}', '1906-01-01', 'year', null, 'year', 'confirmed', '00000000-0000-4000-8000-000000000001'),
  (pg_temp.e('gary-land-company'), 'part_of', pg_temp.e('us-steel'), '{"as": "subsidiary"}', '1906-01-01', 'year', null, 'year', 'probable', '00000000-0000-4000-8000-000000000001'),
  (pg_temp.e('us-steel'), 'owns', pg_temp.e('gary-works'), '{}', '1908-01-01', 'year', null, 'year', 'confirmed', null),
  (pg_temp.e('gary-land-company'), 'occupies', pg_temp.e('gary-land-company-building'), '{}', '1906-01-01', 'year', null, 'year', 'probable', null),
  (pg_temp.e('city-of-gary'), 'occupies', pg_temp.e('gary-city-hall'), '{}', '1928-01-01', 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-public-schools'), 'occupies', pg_temp.e('emerson-school'), '{}', '1909-01-01', 'year', '2008-01-01', 'year', 'probable', null),
  (pg_temp.e('city-methodist-congregation'), 'occupies', pg_temp.e('city-methodist-church'), '{}', '1926-01-01', 'year', '1975-01-01', 'year', 'probable', null),
  (pg_temp.e('william-a-wirt'), 'held_office', pg_temp.e('gary-public-schools'), '{"office": "Superintendent"}', '1907-01-01', 'year', '1938-01-01', 'year', 'probable', null),
  (pg_temp.e('richard-g-hatcher'), 'held_office', pg_temp.e('city-of-gary'), '{"office": "Mayor"}', '1968-01-01', 'year', '1987-01-01', 'year', 'probable', '00000000-0000-4000-8000-000000000003'),
  (pg_temp.e('michael-jackson'), 'resides_at', pg_temp.e('jackson-family-home'), '{}', '1958-01-01', 'year', '1969-01-01', 'year', 'probable', null),
  -- located_on / located_in
  (pg_temp.e('palace-theater'), 'located_on', pg_temp.e('broadway'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-city-hall'), 'located_on', pg_temp.e('broadway'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('hotel-gary'), 'located_on', pg_temp.e('broadway'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-union-station'), 'located_on', pg_temp.e('broadway'), '{}', null, 'year', null, 'year', 'approximate', null),
  (pg_temp.e('city-methodist-church'), 'located_on', pg_temp.e('washington-street'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('palace-theater'), 'located_in', pg_temp.e('downtown-gary'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('city-methodist-church'), 'located_in', pg_temp.e('downtown-gary'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('hotel-gary'), 'located_in', pg_temp.e('downtown-gary'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-city-hall'), 'located_in', pg_temp.e('downtown-gary'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-union-station'), 'located_in', pg_temp.e('downtown-gary'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('genesis-convention-center'), 'located_in', pg_temp.e('downtown-gary'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('emerson-school'), 'located_in', pg_temp.e('emerson'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-bathing-beach-aquatorium'), 'located_in', pg_temp.e('miller-beach'), '{}', null, 'year', null, 'year', 'probable', null),
  -- events
  (pg_temp.e('chanute-glider-experiments'), 'occurred_at', pg_temp.e('miller-beach'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('octave-chanute'), 'participant', pg_temp.e('chanute-glider-experiments'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('founding-of-gary'), 'occurred_at', pg_temp.e('downtown-gary'), '{}', null, 'year', null, 'year', 'probable', '00000000-0000-4000-8000-000000000001'),
  (pg_temp.e('us-steel'), 'participant', pg_temp.e('founding-of-gary'), '{"role": "founder"}', null, 'year', null, 'year', 'confirmed', '00000000-0000-4000-8000-000000000001'),
  (pg_temp.e('gary-land-company'), 'participant', pg_temp.e('founding-of-gary'), '{"role": "developer"}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-incorporated-as-city'), 'affected', pg_temp.e('city-of-gary'), '{}', null, 'year', null, 'year', 'probable', '00000000-0000-4000-8000-000000000001'),
  (pg_temp.e('steel-strike-of-1919'), 'occurred_at', pg_temp.e('gary-works'), '{}', null, 'year', null, 'year', 'probable', '00000000-0000-4000-8000-000000000002'),
  (pg_temp.e('us-steel'), 'participant', pg_temp.e('steel-strike-of-1919'), '{"role": "employer"}', null, 'year', null, 'year', 'probable', '00000000-0000-4000-8000-000000000002'),
  (pg_temp.e('hatcher-elected-mayor'), 'affected', pg_temp.e('city-of-gary'), '{}', null, 'year', null, 'year', 'probable', '00000000-0000-4000-8000-000000000003'),
  (pg_temp.e('hatcher-elected-mayor'), 'occurred_at', pg_temp.e('gary-city-hall'), '{}', null, 'year', null, 'year', 'speculative', null),
  (pg_temp.e('richard-g-hatcher'), 'participant', pg_temp.e('hatcher-elected-mayor'), '{"role": "candidate"}', null, 'year', null, 'year', 'probable', '00000000-0000-4000-8000-000000000003'),
  (pg_temp.e('city-methodist-closes'), 'affected', pg_temp.e('city-methodist-church'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('city-methodist-closes'), 'occurred_at', pg_temp.e('city-methodist-church'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('city-methodist-congregation'), 'participant', pg_temp.e('city-methodist-closes'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('miss-usa-in-gary'), 'occurred_at', pg_temp.e('genesis-convention-center'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('emerson-school-closes'), 'affected', pg_temp.e('emerson-school'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('emerson-school-closes'), 'occurred_at', pg_temp.e('emerson-school'), '{}', null, 'year', null, 'year', 'probable', null),
  (pg_temp.e('gary-public-schools'), 'participant', pg_temp.e('emerson-school-closes'), '{}', null, 'year', null, 'year', 'probable', null);

-- -----------------------------------------------------------------------------
-- Tags (hierarchical traits, also temporal)
-- -----------------------------------------------------------------------------
insert into public.entity_tags (entity_id, tag_id, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence)
select pg_temp.e(v.e), (select id from public.tags where slug = v.t),
       v.f::date, coalesce(v.fp, 'year')::public.date_precision, v.u::date, coalesce(v.up, 'year')::public.date_precision, 'probable'
from (values
  ('hotel-gary',            'hotel',          '1927-01-01', 'year',   '1979-01-01', 'decade'),
  ('hotel-gary',            'neoclassical',   null,         null,     null,         null),
  ('palace-theater',        'movie-theater',  '1925-01-01', 'year',   '1972-01-01', 'year'),
  ('palace-theater',        'abandonment',    '1972-01-01', 'year',   null,         null),
  ('city-methodist-church', 'church',         '1926-01-01', 'year',   '1975-01-01', 'year'),
  ('city-methodist-church', 'gothic-revival', null,         null,     null,         null),
  ('city-methodist-church', 'abandonment',    '1975-01-01', 'year',   null,         null),
  ('gary-union-station',    'rail-station',   '1910-01-01', 'year',   '1950-01-01', 'decade'),
  ('gary-union-station',    'beaux-arts',     null,         null,     null,         null),
  ('gary-union-station',    'concrete',       null,         null,     null,         null),
  ('gary-union-station',    'abandonment',    '1950-01-01', 'decade', null,         null),
  ('emerson-school',        'school',         '1909-01-01', 'year',   '2008-01-01', 'year'),
  ('gary-works',            'steel',          null,         null,     null,         null),
  ('us-steel',              'steel',          null,         null,     null,         null),
  ('steel-strike-of-1919',  'labor',          null,         null,     null,         null),
  ('hatcher-elected-mayor', 'civil-rights',   null,         null,     null,         null),
  ('richard-g-hatcher',     'civil-rights',   null,         null,     null,         null),
  ('jackson-family-home',   'music',          null,         null,     null,         null),
  ('michael-jackson',       'music',          null,         null,     null,         null),
  ('founding-of-gary',      'company-town',   null,         null,     null,         null),
  ('gary-city-hall',        'civic',          '1928-01-01', 'year',   null,         null),
  ('gary-city-hall',        'neoclassical',   null,         null,     null,         null)
) v (e, t, f, fp, u, up);

-- -----------------------------------------------------------------------------
-- Article prose (a few to start; the rest are stubs)
-- -----------------------------------------------------------------------------
create function pg_temp.article(p_slug text, p_status text, p_body text) returns void language plpgsql as $$
declare v_id uuid := pg_temp.e(p_slug); v_rev uuid;
begin
  insert into public.article_revisions (entity_id, body, status, edit_summary, author_id)
  values (v_id, p_body, p_status, 'Seed article', null) returning id into v_rev;
  update public.articles set body = p_body, status = p_status, current_revision_id = v_rev where entity_id = v_id;
  if p_status <> 'stub' then
    insert into public.article_status_events (entity_id, from_status, to_status, note, actor_id)
    values (v_id, 'stub', p_status, 'Seed article', null);
  end if;
end;
$$;

select pg_temp.article('city-methodist-church', 'needs_sources', $md$
**City Methodist Church** stands at 577 Washington Street, one block west of [[broadway|Broadway]], in [[downtown-gary|Downtown Gary]].

Completed in 1926 for a fast-growing Methodist congregation, it was conceived as more than a sanctuary: the complex included classrooms, offices, and an auditorium intended to serve the steel city's civic life. Its construction is commonly put at around one million dollars.

## Decline

As downtown emptied out in the decades after the Second World War, the congregation shrank with it. The building closed in 1975 (see [[city-methodist-closes]]). Without heat or maintenance, the roof and interior failed, and the open-air ruin of the sanctuary has since become one of the most photographed abandoned buildings in the Midwest.

## Open questions

- Exact dates for the roof failure and any fires. These are recorded on the timeline as *approximate*.
- The building's name before the 1939 Methodist merger.
$md$);

select pg_temp.article('gary-union-station', 'needs_sources', $md$
**Gary Union Station** is a Beaux-Arts railroad station of poured, reinforced concrete at the north end of [[broadway|Broadway]], built in 1910 beside the elevated tracks.

It served passengers arriving in the new steel city. The station lost its passenger service in the mid-20th century and has stood empty ever since. Its concrete shell has outlasted decades of neglect.

> Contributors: the end of passenger service is recorded as "1950s" (decade precision). A dated citation would let us tighten it.
$md$);

select pg_temp.article('hotel-gary', 'draft', $md$
**Hotel Gary** opened in 1927 at Broadway and 6th Avenue and was the city's grand hotel during the boom years.

The building survived downtown's decline by changing use: it was converted to senior apartments and renamed **Genesis Towers**. Because names are tracked over time, the map shows "Hotel Gary" before the conversion and "Genesis Towers" afterwards.
$md$);

select pg_temp.article('richard-g-hatcher', 'good', $md$
**Richard Gordon Hatcher** (1933–2019) was mayor of Gary from 1968 to 1987. Elected in November 1967 (see [[hatcher-elected-mayor]]), he and Carl Stokes of Cleveland became the first Black mayors of large American cities.

He led the [[city-of-gary|City of Gary]] through two decades of steel-industry decline, white flight, and the hollowing-out of [[downtown-gary|downtown]].
$md$);

select pg_temp.article('steel-strike-of-1919', 'draft', $md$
The **steel strike of 1919** was a national walkout against [[us-steel|U.S. Steel]] and other producers, lasting from September 1919 into January 1920.

In Gary, the strike centered on [[gary-works|Gary Works]]. In October 1919 federal troops under General Leonard Wood were sent to the city and martial law was declared. The strike failed, and steelworkers didn't win union recognition until the 1930s.
$md$);

select pg_temp.article('downtown-gary', 'draft', $md$
**Downtown Gary** is the commercial core platted by the [[gary-land-company|Gary Land Company]] in 1906 along [[broadway|Broadway]], between the mill gates and the rail lines to the north and the residential grid to the south.

Notable places include [[gary-city-hall|City Hall]], [[hotel-gary|Hotel Gary]], the [[palace-theater|Palace Theater]], [[city-methodist-church|City Methodist Church]] and [[gary-union-station|Union Station]].

Drag the time slider on the map to watch the district fill in after 1906 and empty out after the 1960s.
$md$);

select pg_temp.article('broadway', 'stub', $md$
**Broadway** is Gary's main north–south street, running from the [[gary-works|Gary Works]] gates south through [[downtown-gary|downtown]].

*The southern extent shown before 1920 is illustrative. Help wanted: trace the street's actual growth from plat and Sanborn maps.*
$md$);
