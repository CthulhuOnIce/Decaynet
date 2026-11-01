-- =============================================================================
-- Decaynet :: 0006 vocabulary
-- Starting vocabulary. Moderators can extend all of this from the app/DB.
-- =============================================================================

insert into public.entity_kinds (id, label, plural, color, geometry_hint, start_verb, end_verb, sort, description) values
  ('district',       'District',       'Districts',       '#6b6f8f', 'polygon', 'Established',  'Dissolved',   10, 'Neighborhoods, wards, subdivisions, plats.'),
  ('parcel',         'Parcel',         'Parcels',         '#5f6b55', 'polygon', 'Platted',      'Replatted',   20, 'Tax / land parcels and lots.'),
  ('infrastructure', 'Infrastructure', 'Infrastructure',  '#7a6a5a', 'line',    'Built',        'Removed',     30, 'Rail lines, bridges, highways, canals, utilities.'),
  ('street',         'Street',         'Streets',         '#c9b48a', 'line',    'Laid out',     'Vacated',     40, 'Streets, avenues, alleys, boulevards.'),
  ('site',           'Site',           'Sites',           '#7fae6a', 'polygon', 'Established',  'Closed',      50, 'Parks, lots, cemeteries, beaches, landmarks that are not buildings.'),
  ('building',       'Building',       'Buildings',       '#c2562b', 'polygon', 'Built',        'Demolished',  60, 'Structures. Footprints may be a point until traced.'),
  ('organization',   'Organization',   'Organizations',   '#b48ead', null,      'Founded',      'Dissolved',   70, 'Businesses, churches, schools, agencies, clubs.'),
  ('person',         'Person',         'People',          '#d08770', null,      'Born',         'Died',        80, 'People connected to the region.'),
  ('event',          'Event',          'Events',          '#e0a23a', null,      'Began',        'Ended',       90, 'Fires, demolitions, strikes, elections, openings...'),
  ('media',          'Media',          'Media',           '#8fb3c9', null,      'Captured',     'Lost',       100, 'Photos, postcards, maps, documents, video, audio.');

insert into public.lifecycle_statuses (id, label, color, is_extant, decay_level, sort, description) values
  ('proposed',           'Proposed',            '#8a8fb0', false, 0, 10, 'Planned but not yet built.'),
  ('under_construction', 'Under construction',  '#a0b27a', true,  0, 20, null),
  ('active',             'Active / in use',     '#7fae6a', true,  0, 30, 'Open, occupied, operating.'),
  ('restored',           'Restored',            '#5fb39a', true,  0, 35, 'Rehabilitated after decline.'),
  ('repurposed',         'Repurposed',          '#6fa7b0', true,  0, 37, 'In use for something other than its original purpose.'),
  ('declining',          'Declining',           '#c9b04f', true,  1, 40, 'Partially occupied, deferred maintenance.'),
  ('closed',             'Closed',              '#c98f4f', true,  2, 45, 'Operations ended; structure intact and secured.'),
  ('vacant',             'Vacant',              '#d07a3a', true,  2, 50, 'Unoccupied.'),
  ('abandoned',          'Abandoned',           '#c2562b', true,  3, 60, 'Unsecured, unmaintained, open to the elements.'),
  ('fire_damaged',       'Fire damaged',        '#a33a1f', true,  4, 65, null),
  ('ruin',               'Ruin',                '#7d2f1e', true,  4, 70, 'Roof or major structure failed.'),
  ('demolished',         'Demolished',          '#3d3533', false, 5, 80, 'Gone. Lifespan should end here too.'),
  ('empty_lot',          'Empty lot',           '#4c4440', false, 5, 85, 'Site cleared and not rebuilt.'),
  ('vacated',            'Vacated (street)',    '#4c4440', false, 5, 90, 'Street right-of-way closed or removed.');

insert into public.relation_types (id, label, inverse_label, subject_kinds, object_kinds, sort, description) values
  ('occupies',     'occupies',            'occupied by',        '{organization,person}',                 '{building,site,parcel}',                10, 'Tenant / business / congregation in a place.'),
  ('resides_at',   'lived at',            'residence of',       '{person}',                              '{building,parcel}',                     15, null),
  ('owns',         'owns',                'owned by',           '{person,organization}',                 '{building,site,parcel,organization}',   20, null),
  ('located_on',   'is on',               'has frontage for',   '{building,site,parcel}',                '{street}',                              30, 'Frontage / access street (use addresses for numbers).'),
  ('located_in',   'is in',               'contains',           null,                                    '{district,site,parcel}',                35, null),
  ('part_of',      'is part of',          'includes',           null,                                    null,                                    40, null),
  ('intersects',   'crosses',             'crosses',            '{street,infrastructure}',               '{street,infrastructure}',               45, null),
  ('designed_by',  'was designed by',     'designed',           '{building,site,street,district}',       '{person,organization}',                 50, 'Architect, planner, engineer.'),
  ('built_by',     'was built by',        'built',              '{building,site,street,infrastructure}', '{person,organization}',                 55, null),
  ('replaced',     'replaced',            'was replaced by',    null,                                    null,                                    60, 'Successor on the same site or role.'),
  ('named_after',  'is named after',      'namesake of',        null,                                    null,                                    65, null),
  ('employed_by',  'worked for',          'employed',           '{person}',                              '{organization}',                        70, null),
  ('member_of',    'was a member of',     'had member',         '{person,organization}',                 '{organization}',                        72, null),
  ('held_office',  'held office in',      'had officeholder',   '{person}',                              '{organization}',                        74, 'Use qualifiers.office, e.g. {"office": "Mayor"}.'),
  ('founded',      'founded',             'was founded by',     '{person,organization}',                 null,                                    76, null),
  ('occurred_at',  'happened at',         'site of',            '{event}',                               null,                                    80, 'Where an event took place.'),
  ('affected',     'affected',            'was affected by',    '{event}',                               null,                                    82, 'What an event changed or damaged.'),
  ('participant',  'took part in',        'involved',           '{person,organization}',                 '{event}',                               84, null),
  ('depicts',      'depicts',             'depicted in',        '{media}',                               null,                                    90, 'Validity = the period shown, not when the media was added.'),
  ('mentions',     'mentions',            'mentioned in',       '{media}',                               null,                                    92, null);

insert into public.event_types (id, label, color, sort) values
  ('founding',      'Founding',          '#7fae6a', 10),
  ('construction',  'Construction',      '#a0b27a', 15),
  ('opening',       'Opening',           '#8fc07a', 20),
  ('renaming',      'Renaming',          '#d7c9a7', 25),
  ('sale',          'Sale / transfer',   '#b9a68a', 30),
  ('closing',       'Closing',           '#c98f4f', 35),
  ('fire',          'Fire',              '#e0552b', 40),
  ('collapse',      'Collapse',          '#a33a1f', 42),
  ('demolition',    'Demolition',        '#6b5f5a', 45),
  ('disaster',      'Disaster / storm',  '#9b6bb0', 50),
  ('labor',         'Labor action',      '#d9a441', 55),
  ('protest',       'Protest',           '#e07a5f', 57),
  ('election',      'Election',          '#6f8fa6', 60),
  ('crime',         'Crime',             '#8a3b3b', 65),
  ('restoration',   'Restoration',       '#5fb39a', 70),
  ('redevelopment', 'Redevelopment',     '#5f9ea0', 72),
  ('film',          'Film / media shoot','#8fb3c9', 75),
  ('birth',         'Birth',             '#d08770', 80),
  ('other',         'Other',             '#e0a23a', 99);

insert into public.attribute_keys (id, label, value_type, unit, applies_to, sort) values
  ('architect',          'Architect (name as recorded)', 'text',    null,     '{building,site}',              10),
  ('architectural_style','Architectural style',          'text',    null,     '{building}',                   12),
  ('floors',             'Floors',                       'number',  null,     '{building}',                   14),
  ('height',             'Height',                       'number',  'ft',     '{building,infrastructure}',    16),
  ('material',           'Primary material',             'text',    null,     '{building,infrastructure}',    18),
  ('construction_cost',  'Construction cost',            'number',  'USD',    '{building,site,infrastructure}',20),
  ('capacity',           'Capacity / seats',             'number',  null,     '{building,site}',              22),
  ('use',                'Use',                          'text',    null,     '{building,site,parcel}',       24),
  ('owner_of_record',    'Owner of record',              'text',    null,     '{building,site,parcel}',       26),
  ('surface',            'Surface',                      'text',    null,     '{street}',                     30),
  ('lanes',              'Lanes',                        'number',  null,     '{street}',                     32),
  ('route_designation',  'Route designation',            'text',    null,     '{street,infrastructure}',      34),
  ('population',         'Population',                   'number',  null,     '{district}',                   40),
  ('area',               'Area',                         'number',  'acres',  '{district,site,parcel}',       42),
  ('parcel_number',      'Parcel number',                'text',    null,     '{parcel,building}',            44),
  ('nrhp_ref',           'NRHP reference #',             'text',    null,     '{building,site,district}',     50),
  ('occupation',         'Occupation',                   'text',    null,     '{person}',                     60),
  ('industry',           'Industry',                     'text',    null,     '{organization}',               62),
  ('employees',          'Employees',                    'number',  null,     '{organization}',               64),
  ('casualties',         'Casualties',                   'number',  null,     '{event}',                      70),
  ('website',            'Website',                      'url',     null,     null,                           90),
  ('wikidata',           'Wikidata ID',                  'text',    null,     null,                           92);

insert into public.article_statuses (id, label, color, moderator_only, sort, description) values
  ('stub',          'Stub',           '#6b5f5a', false, 10, 'Placeholder; little or no prose.'),
  ('draft',         'Draft',          '#c9b04f', false, 20, 'Being written.'),
  ('needs_sources', 'Needs sources',  '#d07a3a', false, 30, 'Claims lack citations.'),
  ('needs_review',  'Needs review',   '#8fb3c9', false, 40, 'Ready for a second pair of eyes.'),
  ('disputed',      'Disputed',       '#a33a1f', false, 45, 'Facts are contested; see talk/notes.'),
  ('good',          'Good',           '#7fae6a', false, 50, 'Well sourced and reasonably complete.'),
  ('featured',      'Featured',       '#e0a23a', true,  60, 'Exemplary. Moderators only.');
