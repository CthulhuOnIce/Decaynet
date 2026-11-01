-- =============================================================================
-- Decaynet :: 0009 anonymous tips
--
-- Guests submit tips through the app server, which verifies the captcha,
-- applies the rate limit and records the IP according to site settings
-- (off / salted hash / full). Inserts happen with the service role only, so
-- nobody can bypass those checks by calling the API directly. Reviewers with
-- the review_tips permission triage tips and fold them into the wiki.
-- =============================================================================

create table public.tips (
  id uuid primary key default gen_random_uuid(),
  status text not null default 'new'
    check (status in ('new', 'reviewing', 'accepted', 'rejected', 'spam')),
  subject text,
  body text not null check (length(body) between 1 and 20000),
  about_entity_id uuid references public.entities (id) on delete set null,
  about_text text,                   -- place / person / business as the tipster wrote it
  when_text text,                    -- "around 1958", "summer of '67"
  location extensions.geometry(Point, 4326),
  contact text,                      -- optional, only if the tipster wants a reply
  images jsonb not null default '[]'::jsonb,   -- [{path, name, mime, size}] in the private "tips" bucket
  ip_address inet,                   -- only when tips_ip_mode = 'full'
  ip_hash text,                      -- salted sha256, when mode is 'hash' or 'full' (for rate limiting)
  user_agent text,
  captcha_verified boolean not null default false,
  reviewer_id uuid references public.profiles (id) on delete set null,
  reviewer_notes text,
  reviewed_at timestamptz,
  resulting_entity_id uuid references public.entities (id) on delete set null,
  created_at timestamptz not null default now()
);
create index tips_status_idx on public.tips (status, created_at desc);
create index tips_ip_hash_idx on public.tips (ip_hash, created_at desc) where ip_hash is not null;

alter table public.tips enable row level security;
create policy "reviewers read tips" on public.tips for select to authenticated
  using ((select public.has_permission('review_tips')));
create policy "reviewers update tips" on public.tips for update to authenticated
  using ((select public.has_permission('review_tips'))) with check ((select public.has_permission('review_tips')));
create policy "moderators delete tips" on public.tips for delete to authenticated
  using ((select public.has_permission('moderate')));
-- no insert policy: only the service role (app server) inserts

create or replace view public.tips_view with (security_invoker = true) as
  select t.*, extensions.st_asgeojson(t.location, 6)::jsonb as location_geojson,
         e.slug as about_slug, e.name as about_name,
         r.slug as resulting_slug, r.name as resulting_name,
         p.display_name as reviewer_name
    from public.tips t
    left join public.entities e on e.id = t.about_entity_id
    left join public.entities r on r.id = t.resulting_entity_id
    left join public.profiles p on p.id = t.reviewer_id;

-- Private bucket for tip images; reviewers read via signed URLs
insert into storage.buckets (id, name, public)
values ('tips', 'tips', false)
on conflict (id) do nothing;

create policy "tip reviewers read tip files" on storage.objects
  for select to authenticated using (bucket_id = 'tips' and (select public.has_permission('review_tips')));
create policy "moderators delete tip files" on storage.objects
  for delete to authenticated using (bucket_id = 'tips' and (select public.has_permission('moderate')));

-- Review queue counts for the nav badge
create or replace function public.tip_counts()
returns table (status text, n bigint)
language sql stable set search_path = public as $$
  select t.status, count(*) from public.tips t group by t.status
$$;
