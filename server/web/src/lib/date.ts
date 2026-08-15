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
