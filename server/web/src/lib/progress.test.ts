import { describe, expect, test } from "vitest";

import type { ProgressPhoto, ProgressPhotoTag } from "../types";
import {
  comparisonRows,
  defaultComparisonDates,
  groupPhotosByDate,
  latestByDateAndTag,
  toDateKey,
} from "./progress";

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
];

describe("progress transforms", () => {
  test("formats a Date as a local calendar key", () => {
    expect(toDateKey(new Date(2026, 7, 3, 23, 30))).toBe("2026-08-03");
  });

  test("groups photos newest-first and filters by tag", () => {
    const groups = groupPhotosByDate(photos, "front");
    expect(groups.map((group) => group.date)).toEqual(["2026-08-01", "2026-06-01"]);
    expect(groups[0].photos.map((item) => item.id)).toEqual([
      "new-front",
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

  test("chooses the two newest unique photo dates by default", () => {
    expect(defaultComparisonDates(photos)).toEqual({
      left: "2026-06-01",
      right: "2026-08-01",
    });
  });
});
