import { describe, expect, test } from "vitest";

import type { ProgressPhoto } from "../types";
import { buildMonthGrid, photosDayIndex, shiftMonthAnchor } from "./calendar";

/** Build a minimal preview photo row for calendar indexing tests. */
function photo(id: string, date: string): ProgressPhoto {
  return {
    id,
    date,
    tag_id: "front",
    mime: "image/jpeg",
    bytes: 1,
    sha256: id,
    updated_at: `${date}T12:00:00Z`,
  };
}

describe("calendar helpers", () => {
  test("builds a Sunday-start month grid with leading padding", () => {
    const cells = buildMonthGrid(2026, 7);
    expect(cells[0].date).toBeNull();
    expect(cells.find((cell) => cell.date === "2026-08-01")?.dayOfMonth).toBe(1);
  });

  test("indexes populated days with counts and a thumbnail id", () => {
    const index = photosDayIndex([
      photo("a", "2026-08-01"),
      photo("b", "2026-08-01"),
      photo("c", "2026-07-01"),
    ]);
    expect(index.get("2026-08-01")).toEqual({ count: 2, firstPhotoId: "a" });
    expect(index.get("2026-07-01")).toEqual({ count: 1, firstPhotoId: "c" });
  });

  test("shifts month anchors by whole months", () => {
    expect(shiftMonthAnchor("2026-03-01", -1)).toBe("2026-02-01");
    expect(shiftMonthAnchor("2026-03-01", 1)).toBe("2026-04-01");
  });
});
