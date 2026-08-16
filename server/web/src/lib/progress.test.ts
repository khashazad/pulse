import { describe, expect, test } from "vitest";

import type { ProgressPhoto, ProgressPhotoTag } from "../types";
import {
  adjacentCaptureDate,
  comparisonRows,
  defaultComparisonDates,
  groupPhotosByDate,
  latestByDateAndTag,
  nearestCaptureOnOrBefore,
  resolvePresetDate,
  toDateKey,
} from "./progress";
import { tagSortOrder } from "./tags";

const tags: ProgressPhotoTag[] = [
  {
    id: "side",
    name: "Side",
    normalized_name: "side",
    sort_order: 2,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  },
  {
    id: "front",
    name: "Front",
    normalized_name: "front",
    sort_order: 1,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  },
];

/** Build a concise photo fixture for transform tests. */
function photo(
  id: string,
  date: string,
  tagId: string,
  updatedAt = `${date}T12:00:00Z`,
): ProgressPhoto {
  return {
    id,
    date,
    tag_id: tagId,
    mime: "image/jpeg",
    bytes: 1024,
    sha256: `sha-${id}`,
    updated_at: updatedAt,
  };
}

const photos = [
  photo("old-front", "2026-06-01", "front"),
  photo("new-side", "2026-08-01", "side"),
  photo("new-front-old-upload", "2026-08-01", "front", "2026-08-01T09:00:00Z"),
  photo("new-front", "2026-08-01", "front", "2026-08-01T18:00:00Z"),
  photo("mid-front", "2026-07-01", "front"),
];

describe("progress transforms", () => {
  test("formats a Date as a local calendar key", () => {
    expect(toDateKey(new Date(2026, 7, 3, 23, 30))).toBe("2026-08-03");
  });

  test("groups photos newest-first and filters by multi-select tags", () => {
    const groups = groupPhotosByDate(photos, new Set(["front"]));
    expect(groups.map((group) => group.date)).toEqual(["2026-08-01", "2026-07-01", "2026-06-01"]);
    expect(groups[0].photos.map((item) => item.id)).toEqual(["new-front", "new-front-old-upload"]);
  });

  test("orders a day's photos by tag rank ahead of upload recency", () => {
    const [today] = groupPhotosByDate(photos, null, tagSortOrder(tags));
    expect(today.photos.map((item) => item.id)).toEqual([
      "new-front",
      "new-front-old-upload",
      "new-side",
    ]);
  });

  test("falls back to upload recency when no tag order is supplied", () => {
    const [today] = groupPhotosByDate(photos, null);
    expect(today.photos.map((item) => item.id)).toEqual([
      "new-front",
      "new-side",
      "new-front-old-upload",
    ]);
  });

  test("keeps only the latest upload for each date and tag", () => {
    const latest = latestByDateAndTag(photos);
    expect(latest.get("2026-08-01")?.get("front")?.id).toBe("new-front");
  });

  test("builds comparison rows in tag order with missing sides", () => {
    const rows = comparisonRows(photos, tags, "2026-06-01", "2026-08-01");
    expect(rows.map((row) => row.tag.name)).toEqual(["Front", "Side"]);
    expect(rows[0].left?.id).toBe("old-front");
    expect(rows[0].right?.id).toBe("new-front");
    expect(rows[1].left).toBeUndefined();
    expect(rows[1].right?.id).toBe("new-side");
  });

  test("filters comparison rows by selected tags", () => {
    const rows = comparisonRows(photos, tags, "2026-07-01", "2026-08-01", new Set(["front"]));
    expect(rows).toHaveLength(1);
    expect(rows[0].tag.name).toBe("Front");
  });

  test("chooses the two newest unique photo dates by default", () => {
    expect(defaultComparisonDates(photos)).toEqual({
      left: "2026-07-01",
      right: "2026-08-01",
    });
  });

  test("resolves preset dates to the nearest earlier capture", () => {
    const ascending = ["2025-06-01", "2025-12-01", "2026-06-01", "2026-08-01"];
    expect(resolvePresetDate(ascending, "2026-08-01", "first")).toBe("2025-06-01");
    expect(resolvePresetDate(ascending, "2026-08-01", "1m")).toBe("2026-06-01");
    expect(nearestCaptureOnOrBefore(ascending, "2026-07-15")).toBe("2026-06-01");
  });

  test("steps to adjacent capture dates", () => {
    const ascending = ["2026-06-01", "2026-07-01", "2026-08-01"];
    expect(adjacentCaptureDate(ascending, "2026-07-01", -1)).toBe("2026-06-01");
    expect(adjacentCaptureDate(ascending, "2026-07-01", 1)).toBe("2026-08-01");
  });
});
