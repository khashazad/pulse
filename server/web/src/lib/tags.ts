import type { ProgressPhoto, ProgressPhotoTag } from "../types";

/** localStorage key for persisted multi-select tag ids. */
export const TAG_SELECTION_STORAGE_KEY = "pulse-selected-tag-ids";

/** Parse stored tag ids; an empty array means "All". */
export function parseStoredTagIds(raw: string | null): Set<string> | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return null;
    const ids = parsed.filter((value): value is string => typeof value === "string");
    return ids.length > 0 ? new Set(ids) : null;
  } catch {
    return null;
  }
}

/** Serialize the active tag selection for localStorage. */
export function serializeTagIds(selected: Set<string> | null): string {
  if (!selected || selected.size === 0) return "[]";
  return JSON.stringify([...selected]);
}

/** Toggle one tag id within a multi-select set; returns null when nothing remains selected. */
export function toggleTagSelection(
  current: Set<string> | null,
  tagId: string,
): Set<string> | null {
  if (current === null) {
    return new Set([tagId]);
  }
  const next = new Set(current);
  if (next.has(tagId)) {
    next.delete(tagId);
    return next.size > 0 ? next : null;
  }
  next.add(tagId);
  return next;
}

/** Filter photos to the active tag selection; null shows every tag. */
export function filterPhotosByTags(
  photos: ProgressPhoto[],
  selectedTagIds: Set<string> | null,
): ProgressPhoto[] {
  if (!selectedTagIds || selectedTagIds.size === 0) return photos;
  return photos.filter((photo) => selectedTagIds.has(photo.tag_id));
}

/**
 * Index tags by id to their server-defined display rank.
 *
 * @param tags Ordered tag records as returned by the server.
 * @returns Map of tag id to rank, so photo lists can be sorted the same way the
 *   compare view already orders its pairs.
 */
export function tagSortOrder(tags: ProgressPhotoTag[]): Map<string, number> {
  return new Map(
    tags
      .toSorted((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name))
      .map((tag, index) => [tag.id, index]),
  );
}

/** Keep only tags that appear in both selected capture dates. */
export function commonTagsForDates(
  photos: ProgressPhoto[],
  leftDate: string,
  rightDate: string,
): Set<string> {
  const leftTags = new Set(
    photos.filter((photo) => photo.date === leftDate).map((photo) => photo.tag_id),
  );
  const rightTags = new Set(
    photos.filter((photo) => photo.date === rightDate).map((photo) => photo.tag_id),
  );
  const common = new Set<string>();
  for (const tagId of leftTags) {
    if (rightTags.has(tagId)) common.add(tagId);
  }
  return common;
}
