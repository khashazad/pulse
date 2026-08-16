import { parseDateKey, toDateKey } from "./date";
import type { ProgressPhoto } from "../types";

/** One day cell rendered in the month grid; `date` is null for leading padding. */
export interface CalendarCell {
  date: string | null;
  dayOfMonth: number;
}

/** Summary metadata for one capture day used by the calendar UI. */
export interface DayPhotoSummary {
  count: number;
  firstPhotoId: string;
}

/** Build a Sunday-start month grid with null padding cells before day 1. */
export function buildMonthGrid(year: number, month: number): CalendarCell[] {
  const first = new Date(year, month, 1, 12);
  const lastDay = new Date(year, month + 1, 0, 12).getDate();
  const leading = first.getDay();
  const cells: CalendarCell[] = [];
  for (let index = 0; index < leading; index += 1) {
    cells.push({ date: null, dayOfMonth: 0 });
  }
  for (let day = 1; day <= lastDay; day += 1) {
    const date = toDateKey(new Date(year, month, day, 12));
    cells.push({ date, dayOfMonth: day });
  }
  return cells;
}

/** Index photos by capture date with count and the first photo id for thumbnails. */
export function photosDayIndex(photos: ProgressPhoto[]): Map<string, DayPhotoSummary> {
  const index = new Map<string, DayPhotoSummary>();
  for (const photo of photos) {
    const current = index.get(photo.date);
    if (!current) {
      index.set(photo.date, { count: 1, firstPhotoId: photo.id });
    } else {
      index.set(photo.date, { count: current.count + 1, firstPhotoId: current.firstPhotoId });
    }
  }
  return index;
}

/** Return unique capture dates sorted ascending. */
export function sortedCaptureDates(photos: ProgressPhoto[]): string[] {
  return [...new Set(photos.map((photo) => photo.date))].toSorted();
}

/** Shift a month anchor by whole months while preserving day-of-month when possible. */
export function shiftMonthAnchor(date: string, deltaMonths: number): string {
  const parsed = parseDateKey(date);
  parsed.setMonth(parsed.getMonth() + deltaMonths, 1);
  return toDateKey(parsed);
}

/** Parse a month anchor `YYYY-MM-01` into calendar parts. */
export function parseMonthAnchor(anchor: string): { year: number; month: number } {
  const parsed = parseDateKey(anchor);
  return { year: parsed.getFullYear(), month: parsed.getMonth() };
}
