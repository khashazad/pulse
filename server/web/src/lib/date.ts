/** Convert a browser-local date into the server's `YYYY-MM-DD` key. */
export function toDateKey(value: Date): string {
  const year = value.getFullYear();
  const month = String(value.getMonth() + 1).padStart(2, "0");
  const day = String(value.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

/** Parse a server date key at local noon to avoid UTC day shifts. */
export function parseDateKey(value: string): Date {
  const [year, month, day] = value.split("-").map(Number);
  return new Date(year, month - 1, day, 12);
}

/** Shift a server date key by a whole number of calendar years. */
export function shiftDateKeyYears(value: string, years: number): string {
  const date = parseDateKey(value);
  date.setFullYear(date.getFullYear() + years);
  return toDateKey(date);
}

/** Render a full, human-readable date in the browser locale. */
export function formatLongDate(value: string): string {
  return new Intl.DateTimeFormat(undefined, {
    weekday: "long",
    month: "long",
    day: "numeric",
    year: "numeric",
  }).format(parseDateKey(value));
}

/** Render a compact comparison date in the browser locale. */
export function formatShortDate(value: string): string {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
  }).format(parseDateKey(value));
}

/** Shift a server date key by a whole number of calendar days. */
export function shiftDateKeyDays(value: string, days: number): string {
  const date = parseDateKey(value);
  date.setDate(date.getDate() + days);
  return toDateKey(date);
}

/** Shift a server date key by whole calendar months from its current day. */
export function shiftDateKeyMonths(value: string, months: number): string {
  const date = parseDateKey(value);
  date.setMonth(date.getMonth() + months);
  return toDateKey(date);
}

/** Count whole calendar days from `value` back to `reference`, both inclusive at noon. */
export function daysBetween(earlier: string, later: string): number {
  const start = parseDateKey(earlier);
  const end = parseDateKey(later);
  return Math.max(0, Math.round((end.getTime() - start.getTime()) / 86_400_000));
}

/** Render a human relative phrase such as "3 days ago" for one capture date. */
export function formatDaysAgo(value: string, reference = toDateKey(new Date())): string {
  const delta = daysBetween(value, reference);
  if (delta === 0) return "Today";
  if (delta === 1) return "1 day ago";
  return `${delta} days ago`;
}

/** Render a month and year label for calendar navigation. */
export function formatMonthYear(value: string): string {
  return new Intl.DateTimeFormat(undefined, {
    month: "long",
    year: "numeric",
  }).format(parseDateKey(value));
}
