-- =============================================================================
-- Decaynet :: 0003 articles
--
-- Every entity owns exactly one wiki article. Prose is versioned as an
-- append-only revision log, and the editorial status of the article is itself
-- tracked over time (stub -> draft -> needs sources -> good -> featured).
-- =============================================================================

create table public.articles (
  entity_id uuid primary key references public.entities (id) on delete cascade,
  body text not null default '',
  status text not null default 'stub' references public.article_statuses (id),
  locked boolean not null default false,
  current_revision_id uuid,
  word_count integer generated always as (
    coalesce(array_length(regexp_split_to_array(nullif(btrim(body), ''), '\s+'), 1), 0)
  ) stored,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
create index articles_status_idx on public.articles (status);

create table public.article_revisions (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete cascade,
  body text not null,
  status text not null references public.article_statuses (id),
  edit_summary text,
  author_id uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index article_revisions_entity_idx on public.article_revisions (entity_id, created_at desc);

alter table public.articles
  add constraint articles_current_revision_fk
  foreign key (current_revision_id) references public.article_revisions (id) on delete set null;

-- Status timeline: one row per transition
create table public.article_status_events (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete cascade,
  from_status text references public.article_statuses (id),
  to_status text not null references public.article_statuses (id),
  note text,
  actor_id uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index article_status_events_entity_idx on public.article_status_events (entity_id, created_at desc);

-- Every new entity gets a stub article
create or replace function internal.create_stub_article() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.articles (entity_id, body, status) values (new.id, '', 'stub')
  on conflict (entity_id) do nothing;
  insert into public.article_status_events (entity_id, from_status, to_status, note)
  values (new.id, null, 'stub', 'Entity created');
  return new;
end;
$$;

create trigger create_stub_article
  after insert on public.entities
  for each row execute function internal.create_stub_article();

-- Atomic article save: writes revision, updates head, records status transition.
create or replace function public.save_article(
  p_entity uuid,
  p_body text,
  p_summary text default null,
  p_status text default null
) returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  v_article public.articles;
  v_status text;
  v_rev uuid;
begin
  if not public.is_editor() then
    raise exception 'You must be signed in as a contributor to edit articles' using errcode = '42501';
  end if;

  select * into v_article from public.articles where entity_id = p_entity for update;
  if not found then
    raise exception 'No article for entity %', p_entity using errcode = 'P0002';
  end if;
  if v_article.locked and not public.is_moderator() then
    raise exception 'This article is locked' using errcode = '42501';
  end if;

  v_status := coalesce(p_status, v_article.status);
  if v_status <> v_article.status
     and (select moderator_only from public.article_statuses where id = v_status)
     and not public.is_moderator() then
    raise exception 'Only moderators can set status "%"', v_status using errcode = '42501';
  end if;

  insert into public.article_revisions (entity_id, body, status, edit_summary)
  values (p_entity, p_body, v_status, nullif(btrim(p_summary), ''))
  returning id into v_rev;

  update public.articles
     set body = p_body, status = v_status, current_revision_id = v_rev,
         updated_at = now(), updated_by = auth.uid()
   where entity_id = p_entity;

  if v_status <> v_article.status then
    insert into public.article_status_events (entity_id, from_status, to_status, note)
    values (p_entity, v_article.status, v_status, nullif(btrim(p_summary), ''));
  end if;

  return v_rev;
end;
$$;

-- Status-only change (review workflow)
create or replace function public.set_article_status(p_entity uuid, p_status text, p_note text default null)
returns void
language plpgsql security invoker set search_path = public as $$
declare v_from text;
begin
  if not public.is_editor() then
    raise exception 'You must be signed in as a contributor' using errcode = '42501';
  end if;
  if (select moderator_only from public.article_statuses where id = p_status) and not public.is_moderator() then
    raise exception 'Only moderators can set status "%"', p_status using errcode = '42501';
  end if;
  select status into v_from from public.articles where entity_id = p_entity for update;
  if v_from is distinct from p_status then
    update public.articles set status = p_status, updated_at = now(), updated_by = auth.uid()
     where entity_id = p_entity;
    insert into public.article_status_events (entity_id, from_status, to_status, note)
    values (p_entity, v_from, p_status, nullif(btrim(p_note), ''));
  end if;
end;
$$;
