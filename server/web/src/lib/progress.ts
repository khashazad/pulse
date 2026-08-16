import type {
  ComparisonRow,
  PhotoDateGroup,
  ProgressPhoto,
  ProgressPhotoTag,
} from "../types";
import { filterPhotosByTags } from "./tags";
import { shiftDateKeyMonths, shiftDateKeyYears } from "./date";

export { toDateKey } from "./date";
export { filterPhotosByTags } from "./tags";

/** Named compare presets that resolve to the nearest earlier capture date. */
export type ComparePreset = "first" | "1y" | "6m" | "3m" | "1m";

/** Sort two photos by upload time, newest first, with id as a stable tie-breaker. */
function newestUploadFirst(left: ProgressPhoto, right: ProgressPhoto): number {
  const timeOrder = right.updated_at.localeCompare(left.updated_at);
  return timeOrder || right.id.localeCompare(left.id);
}

/**
 * Build a within-day comparator that leads with tag rank so a day's tiles always
 * read in the same order as the compare view's rows.
 *
 * @param tagOrder Map of tag id to display rank; unknown tags sort last.
 * @returns Comparator falling back to upload recency for photos sharing a tag.
 */
function byTagThenUpload(
  tagOrder: Map<string, number>,
): (left: ProgressPhoto, right: ProgressPhoto) => number {
  return (left, right) => {
    const leftRank = tagOrder.get(left.tag_id) ?? Number.MAX_SAFE_INTEGER;
    const rightRank = tagOrder.get(right.tag_id) ?? Number.MAX_SAFE_INTEGER;
    return leftRank - rightRank || newestUploadFirst(left, right);
  };
}

/** Return unique capture dates sorted newest first. */
export function captureDatesNewestFirst(photos: ProgressPhoto[]): string[] {
  return [...new Set(photos.map((photo) => photo.date))].toSorted().toReversed();
}

/** Return unique capture dates sorted oldest first. */
export function captureDatesOldestFirst(photos: ProgressPhoto[]): string[] {
  return [...new Set(photos.map((photo) => photo.date))].toSorted();
}

/** Pick the latest capture date on or before `target` from an ascending date list. */
export function nearestCaptureOnOrBefore(
  datesAscending: string[],
  target: string,
): string | null {
  let match: string | null = null;
  for (const date of datesAscending) {
    if (date <= target) match = date;
    else break;
  }
  return match;
}

/** Step one capture date earlier or later within the sorted ascending list. */
export function adjacentCaptureDate(
  datesAscending: string[],
  current: string,
  direction: -1 | 1,
): string | null {
  const index = datesAscending.indexOf(current);
  if (index === -1) return null;
  const nextIndex = index + direction;
  if (nextIndex < 0 || nextIndex >= datesAscending.length) return null;
  return datesAscending[nextIndex];
}

/** Resolve a quick-compare preset against the available capture timeline. */
export function resolvePresetDate(
  datesAscending: string[],
  latestDate: string,
  preset: ComparePreset,
): string | null {
  if (datesAscending.length === 0) return null;
  if (preset === "first") return datesAscending[0];
  const target =
    preset === "1y"
      ? shiftDateKeyYears(latestDate, -1)
      : preset === "6m"
        ? shiftDateKeyMonths(latestDate, -6)
        : preset === "3m"
          ? shiftDateKeyMonths(latestDate, -3)
          : shiftDateKeyMonths(latestDate, -1);
  return nearestCaptureOnOrBefore(datesAscending, target);
}

/**
 * Group photos under newest-first dates, optionally limiting them to selected tags.
 *
 * @param photos Photo metadata in any order.
 * @param selectedTagIds Active tag selection; null or empty shows every tag.
 * @param tagOrder Optional tag id to rank map; when omitted a day's photos stay in
 *   upload-recency order.
 * @returns Newest-first date groups whose photos follow tag rank then upload recency.
 */
export function groupPhotosByDate(
  photos: ProgressPhoto[],
  selectedTagIds: Set<string> | null,
  tagOrder: Map<string, number> = new Map(),
): PhotoDateGroup[] {
  const filtered = filterPhotosByTags(photos, selectedTagIds);
  const grouped = new Map<string, ProgressPhoto[]>();
  for (const photo of filtered) {
    const day = grouped.get(photo.date) ?? [];
    day.push(photo);
    grouped.set(photo.date, day);
  }
  const withinDay = byTagThenUpload(tagOrder);
  return [...grouped.entries()]
    .sort(([left], [right]) => right.localeCompare(left))
    .map(([date, dayPhotos]) => ({
      date,
      photos: dayPhotos.toSorted(withinDay),
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
  selectedTagIds: Set<string> | null = null,
): ComparisonRow[] {
  const latest = latestByDateAndTag(photos);
  const left = latest.get(leftDate) ?? new Map<string, ProgressPhoto>();
  const right = latest.get(rightDate) ?? new Map<string, ProgressPhoto>();
  const visibleTagIds = new Set([...left.keys(), ...right.keys()]);

  return tags
    .filter((tag) => visibleTagIds.has(tag.id))
    .filter((tag) => !selectedTagIds || selectedTagIds.size === 0 || selectedTagIds.has(tag.id))
    .toSorted(
      (a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name),
    )
    .map((tag) => ({ tag, left: left.get(tag.id), right: right.get(tag.id) }));
}

/** Select the two newest unique photo dates in chronological comparison order. */
export function defaultComparisonDates(
  photos: ProgressPhoto[],
): { left: string; right: string } | null {
  const dates = captureDatesNewestFirst(photos);
  if (dates.length === 0) return null;
  if (dates.length === 1) return { left: dates[0], right: dates[0] };
  return { left: dates[1], right: dates[0] };
}

/**
 * Flatten the active gallery filter into fullscreen navigation order.
 *
 * @param photos Photo metadata in any order.
 * @param selectedTagIds Active tag selection; null or empty shows every tag.
 * @param tagOrder Optional tag id to rank map, matching the on-screen tile order.
 * @returns Photos in the same order the timeline renders them.
 */
export function galleryPhotoOrder(
  photos: ProgressPhoto[],
  selectedTagIds: Set<string> | null,
  tagOrder: Map<string, number> = new Map(),
): ProgressPhoto[] {
  return groupPhotosByDate(photos, selectedTagIds, tagOrder).flatMap((group) => group.photos);
}

/** Find the previous capture date strictly before `date`, if any. */
export function previousCaptureDate(
  datesAscending: string[],
  date: string,
): string | null {
  const index = datesAscending.indexOf(date);
  if (index <= 0) return null;
  return datesAscending[index - 1];
}

/** Compute weight delta between two dates when both readings exist. */
export function weightDelta(
  weightsByDate: Map<string, number>,
  earlierDate: string,
  laterDate: string,
): number | null {
  const earlier = weightsByDate.get(earlierDate);
  const later = weightsByDate.get(laterDate);
  if (earlier === undefined || later === undefined) return null;
  return later - earlier;
}
