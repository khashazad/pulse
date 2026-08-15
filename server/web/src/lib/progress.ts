import type {
  ComparisonRow,
  PhotoDateGroup,
  ProgressPhoto,
  ProgressPhotoTag,
} from "../types";

export { toDateKey } from "./date";

/** Sort two photos by upload time, newest first, with id as a stable tie-breaker. */
function newestUploadFirst(left: ProgressPhoto, right: ProgressPhoto): number {
  const timeOrder = right.updated_at.localeCompare(left.updated_at);
  return timeOrder || right.id.localeCompare(left.id);
}

/** Group photos under newest-first dates, optionally limiting them to one tag. */
export function groupPhotosByDate(
  photos: ProgressPhoto[],
  tagId: string | null,
): PhotoDateGroup[] {
  const grouped = new Map<string, ProgressPhoto[]>();
  for (const photo of photos) {
    if (tagId !== null && photo.tag_id !== tagId) continue;
    const day = grouped.get(photo.date) ?? [];
    day.push(photo);
    grouped.set(photo.date, day);
  }
  return [...grouped.entries()]
    .sort(([left], [right]) => right.localeCompare(left))
    .map(([date, dayPhotos]) => ({
      date,
      photos: dayPhotos.toSorted(newestUploadFirst),
    }));
}

/** Keep the most recently uploaded photo for each `(date, tag)` pair. */
export function latestByDateAndTag(
  photos: ProgressPhoto[],
): Map<string, Map<string, ProgressPhoto>> {
  const result = new Map<string, Map<string, ProgressPhoto>>();
  for (const photo of photos) {
    const day = result.get(photo.date) ?? new Map<string, ProgressPhoto>();
    const current = day.get(photo.tag_id);
    if (!current || newestUploadFirst(photo, current) < 0) {
      day.set(photo.tag_id, photo);
    }
    result.set(photo.date, day);
  }
  return result;
}

/** Align two selected dates by tag using the server's stable tag ordering. */
export function comparisonRows(
  photos: ProgressPhoto[],
  tags: ProgressPhotoTag[],
  leftDate: string,
  rightDate: string,
): ComparisonRow[] {
  const latest = latestByDateAndTag(photos);
  const left = latest.get(leftDate) ?? new Map<string, ProgressPhoto>();
  const right = latest.get(rightDate) ?? new Map<string, ProgressPhoto>();
  const visibleTagIds = new Set([...left.keys(), ...right.keys()]);

  return tags
    .filter((tag) => visibleTagIds.has(tag.id))
    .toSorted(
      (a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name),
    )
    .map((tag) => ({ tag, left: left.get(tag.id), right: right.get(tag.id) }));
}

/** Select the two newest unique photo dates in chronological comparison order. */
export function defaultComparisonDates(
  photos: ProgressPhoto[],
): { left: string; right: string } | null {
  const dates = [...new Set(photos.map((photo) => photo.date))].toSorted().toReversed();
  if (dates.length === 0) return null;
  if (dates.length === 1) return { left: dates[0], right: dates[0] };
  return { left: dates[1], right: dates[0] };
}

/** Flatten the active gallery filter into fullscreen navigation order. */
export function galleryPhotoOrder(
  photos: ProgressPhoto[],
  tagId: string | null,
): ProgressPhoto[] {
  return groupPhotosByDate(photos, tagId).flatMap((group) => group.photos);
}
