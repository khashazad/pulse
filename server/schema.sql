create extension if not exists pgcrypto;

create table if not exists daily_target_profile (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  calories_target integer not null,
  protein_g_target numeric not null,
  carbs_g_target numeric not null,
  fat_g_target numeric not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
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
  basis text,
  serving_size numeric,
  serving_size_unit text,
  calories integer,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint food_memory_one_target check (
    (usda_fdc_id is not null and custom_food_id is null) or
    (usda_fdc_id is null and custom_food_id is not null)
  )
);
create unique index if not exists idx_food_memory_user_key_name on food_memory(user_key, normalized_name);
create index if not exists idx_food_memory_user_key on food_memory(user_key);

create table if not exists meals (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  name text not null,
  normalized_name text not null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists idx_meals_user_key_name on meals(user_key, normalized_name);
create index if not exists idx_meals_user_key on meals(user_key);

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
  constraint food_entries_one_source check (
    (usda_fdc_id is not null and custom_food_id is null) or
    (usda_fdc_id is null and custom_food_id is not null)
  )
);
create index if not exists idx_food_entries_user_key on food_entries(user_key);
create index if not exists idx_food_entries_daily_log_id_consumed_at on food_entries(daily_log_id, consumed_at);

alter table food_entries add column if not exists custom_food_id uuid references custom_foods(id) on delete restrict;

create index if not exists idx_food_entries_custom_food_id on food_entries(custom_food_id);

do $body$
begin
  if exists (
    select 1 from information_schema.columns
    where table_name = 'food_entries' and column_name = 'custom_food_id' and is_nullable = 'YES'
  ) and not exists (
    select 1 from information_schema.columns
    where table_name = 'food_entries' and column_name = 'usda_fdc_id' and is_nullable = 'YES'
  ) then
    alter table food_entries alter column usda_fdc_id drop not null;
    alter table food_entries alter column usda_description drop not null;
  end if;
end
$body$;

do $body$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'food_entries_one_source'
  ) then
    alter table food_entries add constraint food_entries_one_source check (
      (usda_fdc_id is not null and custom_food_id is null) or
      (usda_fdc_id is null and custom_food_id is not null)
    );
  end if;
end
$body$;

alter table food_entries add column if not exists meal_id uuid;
alter table food_entries add column if not exists meal_name text;

do $body$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'fk_food_entries_meal_id'
  ) then
    alter table food_entries
      add constraint fk_food_entries_meal_id
      foreign key (meal_id) references meals(id) on delete set null;
  end if;
end
$body$;

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
  tag_id uuid not null references progress_photo_tags(id) on delete restrict,
  photo bytea not null,
  photo_thumb bytea not null,
  photo_mime text not null default 'image/jpeg',
  bytes integer not null,
  sha256 text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One-time migration from the legacy fixed-slot model to per-user tags.
-- Safe to run repeatedly: the column / constraint guards skip on already-migrated
-- deployments.
do $body$
begin
  if exists (
    select 1 from information_schema.columns
    where table_name = 'progress_photos' and column_name = 'slot'
  ) then
    -- Pre-existing prod tables were bootstrapped before tag_id existed; the
    -- new CREATE TABLE above is skipped (table exists), so ensure the column
    -- is present before we try to populate it.
    alter table progress_photos add column if not exists tag_id uuid;

    insert into progress_photo_tags (user_key, name, normalized_name, sort_order)
    select user_key, slot, slot,
           case slot when 'front' then 0
                    when 'left'  then 1
                    when 'right' then 2
                    when 'back'  then 3
                    else 4 end
      from progress_photos
     where slot is not null
     group by user_key, slot
    on conflict (user_key, normalized_name) do nothing;

    update progress_photos pp
       set tag_id = t.id
      from progress_photo_tags t
     where pp.tag_id is null
       and pp.user_key = t.user_key
       and pp.slot = t.normalized_name;

    alter table progress_photos drop constraint if exists progress_photos_slot_check;
    alter table progress_photos drop constraint if exists uq_progress_photos_user_date_slot;
    alter table progress_photos drop column slot;
    alter table progress_photos alter column tag_id set not null;
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'fk_progress_photos_tag_id'
  ) then
    alter table progress_photos
      add constraint fk_progress_photos_tag_id
      foreign key (tag_id) references progress_photo_tags(id) on delete restrict;
  end if;
end
$body$;

drop index if exists idx_progress_photos_user_date;
create index if not exists idx_progress_photos_user_date_tag
  on progress_photos (user_key, log_date desc, tag_id);

alter table progress_photos add column if not exists idempotency_key uuid;
create unique index if not exists uq_progress_photos_user_idem
  on progress_photos (user_key, idempotency_key)
  where idempotency_key is not null;

alter table food_memory add column if not exists aliases text[] not null default '{}'::text[];
alter table meals add column if not exists aliases text[] not null default '{}'::text[];

create index if not exists idx_food_memory_aliases on food_memory using gin (aliases);
create index if not exists idx_meals_aliases on meals using gin (aliases);

do $body$
begin
  if not exists (select 1 from pg_constraint where conname = 'food_memory_alias_not_self') then
    alter table food_memory add constraint food_memory_alias_not_self
      check (not (normalized_name = ANY(aliases)));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'meals_alias_not_self') then
    alter table meals add constraint meals_alias_not_self
      check (not (normalized_name = ANY(aliases)));
  end if;
end
$body$;

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

-- search_path pinned to '' with schema-qualified table refs (Supabase lint 0011).
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

alter table daily_target_profile
  add column if not exists target_weight_lb numeric(6,2);

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
