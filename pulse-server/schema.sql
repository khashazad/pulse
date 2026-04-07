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

create table if not exists food_entries (
  id uuid primary key default gen_random_uuid(),
  daily_log_id uuid not null references daily_logs(id) on delete cascade,
  user_key text not null,
  entry_group_id uuid not null,
  display_name text not null,
  quantity_text text not null,
  normalized_quantity_value numeric,
  normalized_quantity_unit text,
  usda_fdc_id bigint not null,
  usda_description text not null,
  calories integer not null,
  protein_g numeric not null,
  carbs_g numeric not null,
  fat_g numeric not null,
  consumed_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_food_entries_user_key on food_entries(user_key);
create index if not exists idx_food_entries_daily_log_id_consumed_at
  on food_entries(daily_log_id, consumed_at);

create table if not exists food_aliases (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  alias_text text not null,
  preferred_label text not null,
  default_quantity_value numeric,
  default_quantity_unit text,
  preferred_usda_fdc_id bigint not null,
  preferred_usda_description text not null,
  confidence_score numeric not null default 0,
  last_confirmed_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_key, alias_text)
);
create index if not exists idx_food_aliases_user_key on food_aliases(user_key);

create table if not exists food_match_history (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  raw_phrase text not null,
  quantity_text text,
  usda_fdc_id bigint not null,
  usda_description text not null,
  times_confirmed integer not null default 1,
  last_confirmed_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_food_match_history_user_key on food_match_history(user_key);
create unique index if not exists idx_food_match_history_match_key
  on food_match_history(user_key, raw_phrase, coalesce(quantity_text, ''), usda_fdc_id);
