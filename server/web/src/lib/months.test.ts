import { describe, expect, test } from "vitest";

import { monthBucketsOldestFirst } from "./months";

describe("month buckets", () => {
  test("labels months bare when the calendar month occurs only once", () => {
    const buckets = monthBucketsOldestFirst(["2026-06-01", "2026-07-14", "2026-08-08"]);
    expect(buckets.map((bucket) => bucket.label)).toEqual(["JUN", "JUL", "AUG"]);
  });

  test("qualifies a month with its year once it recurs across years", () => {
    const buckets = monthBucketsOldestFirst([
      "2025-08-08",
      "2025-12-01",
      "2026-01-12",
      "2026-08-08",
    ]);
    expect(buckets.map((bucket) => bucket.label)).toEqual(["AUG '25", "DEC", "JAN '26", "AUG '26"]);
  });

  test("picks each bucket's newest capture date as the scroll anchor", () => {
    const buckets = monthBucketsOldestFirst(["2026-08-01", "2026-08-20", "2026-08-08"]);
    expect(buckets).toEqual([{ key: "2026-08", label: "AUG", anchorDate: "2026-08-20" }]);
  });
});
