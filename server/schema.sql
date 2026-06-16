-- Pulse database schema — single source of truth.
--
-- `bootstrap_schema()` (db.py) executes this file idempotently inside one
-- transaction on every startup; the live database shape is whatever this file
-- produces. `repositories/tables.py` mirrors these definitions for the
-- SQLAlchemy-Core query builder and must be kept in sync by hand.
--
-- Change policy (no Alembic): schema changes land here as idempotent guarded
-- statements (`ADD COLUMN IF NOT EXISTS`, conditional DO-blocks) appended after
-- the table they alter. Once a change has reached every deployment, fold it
-- into the final-shape CREATE TABLE below and delete the guard — keeping this
-- file readable as the current schema rather than its migration history.
-- NOTE: columns added via ALTER sit *last* in the live table's column order,
-- so when folding a column in, keep it at the end of the column list — that
-- keeps fresh bootstraps byte-identical to migrated databases.
--
-- Exception: the `mcp_oauth_kv` table is library-managed — auto-created by the
-- MCP OAuth-state store (src/pulse_server/mcp/storage.py) — and is
-- intentionally absent from this file. Do not add it here.
--
-- Supported database states: a fresh/empty database, or one already at (or
-- ahead of) the shape this file produces. Pre-squash states are NOT upgraded —
-- the old in-place migration guards were folded away once every deployment
-- reached final shape. Do not boot the server against a database restored from
-- a pre-squash dump; restore from a current-shape backup instead
-- (scripts/backup_db.sh dumps the live schema, so its output is always
-- current-shape as of dump time).

create extension if not exists pgcrypto;

create table if not exists daily_target_profile (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  calories_target integer not null,
  protein_g_target numeric not null,
  carbs_g_target numeric not null,
  fat_g_target numeric not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  target_weight_lb numeric(6,2)
);
create unique index if not exists idx_daily_target_profile_user_key on daily_target_profile(user_key);

create table if not exists daily_logs (
  id uuid primary key,
  user_key text not null,
  log_date date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_key, log_date)
);
create index if not exists idx_daily_logs_user_key on daily_logs(user_key);

create table if not exists custom_foods (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  name text not null,
  normalized_name text not null,
  basis text not null check (basis in ('per_100g','per_serving','per_unit')),
  serving_size numeric,
  serving_size_unit text,
  calories integer not null,
  protein_g numeric not null,
  carbs_g numeric not null,
  fat_g numeric not null,
  source text not null default 'manual' check (source in ('manual','photo','corrected')),
  notes text,
  food_id uuid,
  portion_label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists idx_custom_foods_user_key_name on custom_foods(user_key, normalized_name);
create index if not exists idx_custom_foods_user_key on custom_foods(user_key);

create table if not exists food_memory (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  name text not null,
  normalized_name text not null,
  usda_fdc_id bigint,
  usda_description text,
  custom_food_id uuid references custom_foods(id) on delete cascade,
  food_id uuid,
  basis text,
  serving_size numeric,
  serving_size_unit text,
  calories integer,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  aliases text[] not null default '{}'::text[],
  constraint food_memory_one_target check (
    (usda_fdc_id is not null)::int
    + (custom_food_id is not null)::int
    + (food_id is not null)::int = 1
  ),
  constraint food_memory_alias_not_self check (not (normalized_name = ANY(aliases)))
);
create unique index if not exists idx_food_memory_user_key_name on food_memory(user_key, normalized_name);
create index if not exists idx_food_memory_user_key on food_memory(user_key);
create index if not exists idx_food_memory_aliases on food_memory using gin (aliases);

-- Foods: a thin parent grouping portion-variants of one food (e.g. "Apple"
-- owning small/medium/large/per-100g). A custom_foods row IS a portion; a Food
-- carries no macros. Aliases for a Food live in food_memory (food_id target),
-- not here, so resolution has a single store.
create table if not exists foods (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  name text not null,
  normalized_name text not null,
  notes text,
  default_portion_id uuid references custom_foods(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists idx_foods_user_key_name on foods(user_key, normalized_name);
create index if not exists idx_foods_user_key on foods(user_key);

-- A custom_foods row becomes a portion of a Food via food_id + portion_label.
-- The columns live in the CREATE body above (for fresh DBs); these guards add
-- them to already-deployed DBs. The food_id FK is added separately as a named
-- constraint because foods is created after custom_foods (FK cycle) — an inline
-- reference in the CREATE body would point at a not-yet-existing table.
alter table custom_foods add column if not exists food_id uuid;
alter table custom_foods add column if not exists portion_label text;
-- on delete set null: ungrouping a Food leaves its portions as standalones.
alter table custom_foods drop constraint if exists custom_foods_food_id_fkey;
alter table custom_foods add constraint custom_foods_food_id_fkey
  foreign key (food_id) references foods(id) on delete set null;
create index if not exists idx_custom_foods_food_id on custom_foods(food_id);

-- food_memory gains a Food target alongside USDA / custom-food targets.
alter table food_memory add column if not exists food_id uuid;
alter table food_memory drop constraint if exists food_memory_food_id_fkey;
alter table food_memory add constraint food_memory_food_id_fkey
  foreign key (food_id) references foods(id) on delete cascade;
alter table food_memory drop constraint if exists food_memory_one_target;
alter table food_memory add constraint food_memory_one_target check (
  (usda_fdc_id is not null)::int
  + (custom_food_id is not null)::int
  + (food_id is not null)::int = 1
);

create table if not exists meals (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  name text not null,
  normalized_name text not null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  aliases text[] not null default '{}'::text[],
  constraint meals_alias_not_self check (not (normalized_name = ANY(aliases)))
);
create unique index if not exists idx_meals_user_key_name on meals(user_key, normalized_name);
create index if not exists idx_meals_user_key on meals(user_key);
create index if not exists idx_meals_aliases on meals using gin (aliases);

create table if not exists meal_items (
  id uuid primary key default gen_random_uuid(),
  meal_id uuid not null references meals(id) on delete cascade,
  position integer not null,
  display_name text not null,
  quantity_text text not null,
  normalized_quantity_value numeric,
  normalized_quantity_unit text,
  usda_fdc_id bigint,
  usda_description text,
  custom_food_id uuid references custom_foods(id) on delete restrict,
  calories integer not null,
  protein_g numeric not null,
  carbs_g numeric not null,
  fat_g numeric not null,
  created_at timestamptz not null default now(),
  constraint meal_items_one_source check (
    (usda_fdc_id is not null and custom_food_id is null) or
    (usda_fdc_id is null and custom_food_id is not null)
  )
);
create index if not exists idx_meal_items_meal_id on meal_items(meal_id, position);

create table if not exists food_entries (
  id uuid primary key default gen_random_uuid(),
  daily_log_id uuid not null references daily_logs(id) on delete cascade,
  user_key text not null,
  entry_group_id uuid not null,
  display_name text not null,
  quantity_text text not null,
  normalized_quantity_value numeric,
  normalized_quantity_unit text,
  usda_fdc_id bigint,
  usda_description text,
  custom_food_id uuid references custom_foods(id) on delete restrict,
  calories integer not null,
  protein_g numeric not null,
  carbs_g numeric not null,
  fat_g numeric not null,
  consumed_at timestamptz not null,
  created_at timestamptz not null default now(),
  meal_id uuid,
  meal_name text,
  confirmed boolean not null default true,
  constraint food_entries_one_source check (
    (usda_fdc_id is not null and custom_food_id is null) or
    (usda_fdc_id is null and custom_food_id is not null)
  ),
  constraint fk_food_entries_meal_id foreign key (meal_id) references meals(id) on delete set null
);
-- Future-dated prep portions land unconfirmed; excluded from all totals until
-- the user confirms them. Guarded for databases created before this column.
alter table food_entries add column if not exists confirmed boolean not null default true;
create index if not exists idx_food_entries_user_key on food_entries(user_key);
create index if not exists idx_food_entries_daily_log_id_consumed_at on food_entries(daily_log_id, consumed_at);
create index if not exists idx_food_entries_custom_food_id on food_entries(custom_food_id);
create index if not exists idx_food_entries_meal_id on food_entries(meal_id);

create table if not exists sessions (
  token_hash    bytea primary key,
  email         text not null,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz not null default now(),
  expires_at    timestamptz not null
);
create index if not exists idx_sessions_email on sessions (email);
create index if not exists idx_sessions_expires_at on sessions (expires_at);

-- Short-lived, single-use authorization codes bridging the OAuth callback and
-- the app's PKCE token exchange. The callback stores sha256(code) + the PKCE
-- code_challenge here instead of returning the bearer token in the redirect URL.
create table if not exists auth_exchange_codes (
  code_hash      bytea primary key,
  email          text not null,
  code_challenge text not null,
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null
);
create index if not exists idx_auth_exchange_codes_expires_at on auth_exchange_codes (expires_at);

create table if not exists containers (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  name text not null,
  normalized_name text not null,
  tare_weight_g numeric not null check (tare_weight_g > 0),
  photo bytea,
  photo_thumb bytea,
  photo_mime text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists idx_containers_user_key_name on containers(user_key, normalized_name);
create index if not exists idx_containers_user_key on containers(user_key);

create table if not exists progress_photo_tags (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  name text not null,
  normalized_name text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_key, normalized_name)
);
create index if not exists idx_progress_photo_tags_user_key
  on progress_photo_tags(user_key, sort_order, normalized_name);

create table if not exists progress_photos (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  log_date date not null,
  tag_id uuid not null,
  photo_mime text not null default 'image/jpeg',
  bytes integer not null,
  sha256 text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  idempotency_key uuid,
  storage_key_prefix text not null,
  constraint fk_progress_photos_tag_id
    foreign key (tag_id) references progress_photo_tags(id) on delete restrict
);
create index if not exists idx_progress_photos_user_date_tag
  on progress_photos (user_key, log_date desc, tag_id);
create unique index if not exists uq_progress_photos_user_idem
  on progress_photos (user_key, idempotency_key)
  where idempotency_key is not null;

-- Object-storage cutover (2026-06) complete: photo bytes live in the S3 store
-- (display/archive/thumb objects under each row's storage_key_prefix).
alter table progress_photos drop column if exists photo;
alter table progress_photos drop column if exists photo_thumb;
alter table progress_photos add column if not exists storage_key_prefix text;
alter table progress_photos alter column storage_key_prefix set not null;

create table if not exists weight_entries (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  log_date date not null,
  weight_lb numeric(6,2) not null check (weight_lb > 0),
  source_unit text not null check (source_unit in ('lb','kg')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_key, log_date)
);
create index if not exists idx_weight_entries_user_key_log_date
  on weight_entries(user_key, log_date);

-- search_path is pinned to '' and all table references are schema-qualified to
-- satisfy Supabase linter 0011 (function_search_path_mutable). pg_catalog is
-- still implicitly searched, so built-ins resolve without qualification.
create or replace function check_food_memory_alias_uniqueness() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  collision_name text;
begin
  if NEW.aliases is not null and array_length(NEW.aliases, 1) is not null then
    select normalized_name into collision_name from public.food_memory
    where user_key = NEW.user_key and id is distinct from NEW.id
      and normalized_name = ANY(NEW.aliases)
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with canonical name %', collision_name using errcode = '23505';
    end if;
    select normalized_name into collision_name from public.food_memory
    where user_key = NEW.user_key and id is distinct from NEW.id
      and aliases && NEW.aliases
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with alias of %', collision_name using errcode = '23505';
    end if;
  end if;
  select normalized_name into collision_name from public.food_memory
  where user_key = NEW.user_key and id is distinct from NEW.id
    and NEW.normalized_name = ANY(aliases)
  limit 1;
  if collision_name is not null then
    raise exception 'name collides with alias of %', collision_name using errcode = '23505';
  end if;
  return NEW;
end;
$$;

create or replace function check_meals_alias_uniqueness() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  collision_name text;
begin
  if NEW.aliases is not null and array_length(NEW.aliases, 1) is not null then
    select normalized_name into collision_name from public.meals
    where user_key = NEW.user_key and id is distinct from NEW.id
      and normalized_name = ANY(NEW.aliases)
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with canonical name %', collision_name using errcode = '23505';
    end if;
    select normalized_name into collision_name from public.meals
    where user_key = NEW.user_key and id is distinct from NEW.id
      and aliases && NEW.aliases
    limit 1;
    if collision_name is not null then
      raise exception 'alias collides with alias of %', collision_name using errcode = '23505';
    end if;
  end if;
  select normalized_name into collision_name from public.meals
  where user_key = NEW.user_key and id is distinct from NEW.id
    and NEW.normalized_name = ANY(aliases)
  limit 1;
  if collision_name is not null then
    raise exception 'name collides with alias of %', collision_name using errcode = '23505';
  end if;
  return NEW;
end;
$$;

drop trigger if exists food_memory_alias_uniqueness on food_memory;
create trigger food_memory_alias_uniqueness
  before insert or update on food_memory
  for each row execute function check_food_memory_alias_uniqueness();

drop trigger if exists meals_alias_uniqueness on meals;
create trigger meals_alias_uniqueness
  before insert or update on meals
  for each row execute function check_meals_alias_uniqueness();

-- Keep public tables off the Supabase Data API surface (lints 0026/0027,
-- pg_graphql anon/authenticated table exposed). The backend connects as the
-- `postgres` owner, which is unaffected by these grants. Guarded on role
-- existence so this is a no-op on local/test Postgres, which has no `anon`/
-- `authenticated` roles and would otherwise fail to boot here. RLS is enabled
-- separately on each table on the live database.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon')
     and exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on all tables in schema public from anon, authenticated';
    execute 'alter default privileges for role postgres in schema public '
         || 'revoke all on tables from anon, authenticated';
  end if;
end
$$;
