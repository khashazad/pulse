import { parseDateKey, shiftDateKeyDays, toDateKey } from "./date";

/** One inclusive calendar span the server accepts in a single range read. */
export interface DateWindow {
  from: string;
  to: string;
}

/** Count inclusive calendar days between two server date keys. */
export function inclusiveDayCount(from: string, to: string): number {
  const start = parseDateKey(from);
  const end = parseDateKey(to);
  const diffMs = end.getTime() - start.getTime();
  return Math.floor(diffMs / 86_400_000) + 1;
}

/** Split an inclusive span into windows no wider than `maxDays` calendar days. */
export function splitDateRange(from: string, to: string, maxDays = 366): DateWindow[] {
  if (from > to) return [];
  const windows: DateWindow[] = [];
  let cursor = from;
  while (cursor <= to) {
    const tentativeEnd = shiftDateKeyDays(cursor, maxDays - 1);
    const windowEnd = tentativeEnd > to ? to : tentativeEnd;
    windows.push({ from: cursor, to: windowEnd });
    if (windowEnd >= to) break;
    cursor = shiftDateKeyDays(windowEnd, 1);
  }
  return windows;
}

/** Return true when every day in `[from, to]` lies inside the loaded span. */
export function isRangeLoaded(
  loadedFrom: string,
  loadedTo: string,
  from: string,
  to: string,
): boolean {
  return loadedFrom <= from && loadedTo >= to;
}

/** List windows inside `[from, to]` that are not yet covered by the loaded span. */
export function missingWindows(
  loadedFrom: string | null,
  loadedTo: string | null,
  from: string,
  to: string,
  maxDays = 366,
): DateWindow[] {
  const requested = splitDateRange(from, to, maxDays);
  if (loadedFrom === null || loadedTo === null) return requested;
  return requested.filter(
    (window) => !isRangeLoaded(loadedFrom, loadedTo, window.from, window.to),
  );
}

/** Merge two loaded spans into one contiguous `[from, to]` envelope. */
export function mergeLoadedSpan(
  current: DateWindow | null,
  incoming: DateWindow,
): DateWindow {
  if (!current) return incoming;
  return {
    from: incoming.from < current.from ? incoming.from : current.from,
    to: incoming.to > current.to ? incoming.to : current.to,
  };
}

/** Return the first and last day of the calendar month containing `date`. */
export function monthBounds(date: string): DateWindow {
  const parsed = parseDateKey(date);
  const start = new Date(parsed.getFullYear(), parsed.getMonth(), 1, 12);
  const end = new Date(parsed.getFullYear(), parsed.getMonth() + 1, 0, 12);
  return { from: toDateKey(start), to: toDateKey(end) };
}
