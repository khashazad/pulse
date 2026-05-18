"""Replace fixed progress-photo slots with per-user tags.

Revision ID: 20260518_000001
Revises: 20260513_000001
Create Date: 2026-05-18T00:00:00Z
"""

from __future__ import annotations

from alembic import op


revision = "20260518_000001"
down_revision = "20260513_000001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        create table if not exists progress_photo_tags (
          id uuid primary key default gen_random_uuid(),
          user_key text not null,
          name text not null,
          normalized_name text not null,
          sort_order integer not null default 0,
          created_at timestamptz not null default now(),
          updated_at timestamptz not null default now(),
          unique (user_key, normalized_name)
        )
        """
    )
    op.execute(
        "create index if not exists idx_progress_photo_tags_user_key "
        "on progress_photo_tags(user_key, sort_order, normalized_name)"
    )

    # Seed a tag row per distinct (user_key, slot) found in existing photos
    # so the FK switchover below has a target. We preserve the original slot
    # name as the user-visible tag name.
    op.execute(
        """
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
        on conflict (user_key, normalized_name) do nothing
        """
    )

    op.execute("alter table progress_photos add column if not exists tag_id uuid")
    op.execute(
        """
        update progress_photos pp
           set tag_id = t.id
          from progress_photo_tags t
         where pp.tag_id is null
           and pp.user_key = t.user_key
           and pp.slot = t.normalized_name
        """
    )

    op.execute(
        "alter table progress_photos "
        "drop constraint if exists progress_photos_slot_check"
    )
    op.execute(
        "alter table progress_photos "
        "drop constraint if exists uq_progress_photos_user_date_slot"
    )
    op.execute("alter table progress_photos drop column if exists slot")
    op.execute("alter table progress_photos alter column tag_id set not null")
    op.execute(
        """
        do $body$
        begin
          if not exists (
            select 1 from pg_constraint where conname = 'fk_progress_photos_tag_id'
          ) then
            alter table progress_photos
              add constraint fk_progress_photos_tag_id
              foreign key (tag_id) references progress_photo_tags(id) on delete restrict;
          end if;
        end
        $body$
        """
    )
    op.execute("drop index if exists idx_progress_photos_user_date")
    op.execute(
        "create index if not exists idx_progress_photos_user_date_tag "
        "on progress_photos(user_key, log_date desc, tag_id)"
    )


def downgrade() -> None:
    op.execute("alter table progress_photos add column if not exists slot text")
    op.execute(
        """
        update progress_photos pp
           set slot = t.normalized_name
          from progress_photo_tags t
         where pp.slot is null and pp.tag_id = t.id
        """
    )
    op.execute(
        "alter table progress_photos drop constraint if exists fk_progress_photos_tag_id"
    )
    op.execute("alter table progress_photos drop column if exists tag_id")
    op.execute(
        "alter table progress_photos "
        "add constraint progress_photos_slot_check "
        "check (slot in ('front','left','right','back'))"
    )
    op.execute(
        "alter table progress_photos alter column slot set not null"
    )
    op.execute(
        "alter table progress_photos "
        "add constraint uq_progress_photos_user_date_slot "
        "unique (user_key, log_date, slot)"
    )
    op.execute("drop index if exists idx_progress_photos_user_date_tag")
    op.execute(
        "create index if not exists idx_progress_photos_user_date "
        "on progress_photos(user_key, log_date desc)"
    )
    op.execute("drop index if exists idx_progress_photo_tags_user_key")
    op.execute("drop table if exists progress_photo_tags")
