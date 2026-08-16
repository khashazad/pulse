import { describe, expect, test } from "vitest";

import type { ProgressPhoto, ProgressPhotoTag } from "../types";
import {
  commonTagsForDates,
  filterPhotosByTags,
  parseStoredTagIds,
  serializeTagIds,
  tagSortOrder,
  toggleTagSelection,
} from "./tags";

/** Build a concise photo fixture for tag-filter tests. */
function photo(date: string, tagId: string): ProgressPhoto {
  return {
    id: `${date}-${tagId}`,
    date,
    tag_id: tagId,
    mime: "image/jpeg",
    bytes: 1,
    sha256: "sha",
    updated_at: `${date}T12:00:00Z`,
  };
}

const photos = [
  photo("2026-08-01", "front"),
  photo("2026-08-01", "side"),
  photo("2026-08-01", "back"),
  photo("2026-07-01", "front"),
];

describe("tag selection helpers", () => {
  test("round-trips stored tag ids", () => {
    const selected = new Set(["front", "side"]);
    expect(parseStoredTagIds(serializeTagIds(selected))).toEqual(selected);
    expect(parseStoredTagIds(serializeTagIds(null))).toBeNull();
  });

  test("toggles tags and resets to null when empty", () => {
    expect(toggleTagSelection(null, "front")).toEqual(new Set(["front"]));
    expect(toggleTagSelection(new Set(["front"]), "front")).toBeNull();
    expect(toggleTagSelection(new Set(["front"]), "side")).toEqual(new Set(["front", "side"]));
  });

  test("filters photos to the active multi-select set", () => {
    expect(filterPhotosByTags(photos, new Set(["front", "side"]))).toHaveLength(3);
    expect(filterPhotosByTags(photos, null)).toHaveLength(4);
  });

  test("finds tags common to two capture dates", () => {
    expect(commonTagsForDates(photos, "2026-08-01", "2026-07-01")).toEqual(new Set(["front"]));
  });

  test("ranks tags by server sort order regardless of input order", () => {
    /** Build a tag fixture carrying only the fields ranking depends on. */
    function tag(id: string, sortOrder: number): ProgressPhotoTag {
      return {
        id,
        name: id,
        normalized_name: id,
        sort_order: sortOrder,
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
      };
    }

    const order = tagSortOrder([tag("back", 2), tag("front", 0), tag("side", 1)]);
    expect([...order.keys()]).toEqual(["front", "side", "back"]);
    expect(order.get("front")).toBe(0);
    expect(order.get("back")).toBe(2);
  });
});
