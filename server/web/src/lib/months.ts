import { parseDateKey } from "./date";
import type { ProgressPhoto } from "../types";

/** One selectable month bucket in the temporal scrubber, newest first. */
export interface MonthBucket {
  /** `YYYY-MM` bucket key. */
  key: string;
  /** Short label, e.g. "AUG" or "JAN '26" at a year boundary. */
  label: string;
  /** Newest capture date within the bucket — the scroll target. */
  anchorDate: string;
}

/** Render a scrubber-chip label, including the year only where it changes. */
function monthLabel(date: Date, showYear: boolean): string {
  const month = date.toLocaleDateString(undefined, { month: "short" }).toUpperCase();
  if (!showYear) return month;
  return `${month} '${String(date.getFullYear()).slice(2)}`;
}

/**
 * Bucket capture dates by calendar month, oldest first, each carrying its
 * newest date as the scroll anchor.
 */
export function monthBucketsOldestFirst(datesDescending: string[]): MonthBucket[] {
  const byKey = new Map<string, string>();
  for (const date of datesDescending) {
    const key = date.slice(0, 7);
    const current = byKey.get(key);
    if (!current || date > current) byKey.set(key, date);
  }

  const keys = [...byKey.keys()].toSorted();

  // A bare month name ("AUG") is ambiguous once the same calendar month
  // recurs across two different years in the loaded history, regardless of
  // which direction a bucket list happens to render in — always qualify it
  // with the year in that case rather than only at the first crossing.
  const monthCounts = new Map<number, number>();
  for (const key of keys) {
    const monthIndex = Number(key.slice(5, 7)) - 1;
    monthCounts.set(monthIndex, (monthCounts.get(monthIndex) ?? 0) + 1);
  }

  let previousYear: number | null = null;

  return keys.map((key) => {
    const anchorDate = byKey.get(key)!;
    const parsed = parseDateKey(anchorDate);
    const year = parsed.getFullYear();
    const monthIndex = parsed.getMonth();
    const ambiguous = (monthCounts.get(monthIndex) ?? 0) > 1;
    const yearBoundary = previousYear !== null && previousYear !== year;
    previousYear = year;
    return { key, label: monthLabel(parsed, ambiguous || yearBoundary), anchorDate };
  });
}

/** Bucket a photo list's capture dates by month, oldest first. */
export function monthBucketsFromPhotos(photos: ProgressPhoto[]): MonthBucket[] {
  return monthBucketsOldestFirst([...new Set(photos.map((photo) => photo.date))].toSorted());
}
