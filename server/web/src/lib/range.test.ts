import { describe, expect, test } from "vitest";

import {
  inclusiveDayCount,
  isRangeLoaded,
  mergeLoadedSpan,
  missingWindows,
  monthBounds,
  splitDateRange,
} from "./range";

describe("range windows", () => {
  test("counts inclusive days between two date keys", () => {
    expect(inclusiveDayCount("2026-01-01", "2026-01-01")).toBe(1);
    expect(inclusiveDayCount("2026-01-01", "2026-12-31")).toBe(365);
  });

  test("splits spans wider than 366 days into compliant windows", () => {
    const windows = splitDateRange("2024-06-01", "2026-06-01");
    expect(windows.length).toBeGreaterThan(1);
    for (const window of windows) {
      expect(inclusiveDayCount(window.from, window.to)).toBeLessThanOrEqual(366);
    }
    expect(windows[0].from).toBe("2024-06-01");
    expect(windows.at(-1)?.to).toBe("2026-06-01");
  });

  test("detects whether a requested span is already loaded", () => {
    expect(isRangeLoaded("2025-01-01", "2026-01-01", "2025-06-01", "2025-12-01")).toBe(true);
    expect(isRangeLoaded("2025-01-01", "2026-01-01", "2024-06-01", "2025-12-01")).toBe(false);
  });

  test("returns only missing windows for incremental loading", () => {
    const missing = missingWindows("2025-06-01", "2026-06-01", "2024-06-01", "2026-06-01");
    expect(missing.length).toBeGreaterThan(0);
    expect(missing.every((window) => !isRangeLoaded("2025-06-01", "2026-06-01", window.from, window.to))).toBe(
      true,
    );
  });

  test("merges loaded spans into one envelope", () => {
    expect(
      mergeLoadedSpan({ from: "2025-01-01", to: "2026-01-01" }, { from: "2024-01-01", to: "2024-12-31" }),
    ).toEqual({ from: "2024-01-01", to: "2026-01-01" });
  });

  test("derives month bounds from a month anchor", () => {
    expect(monthBounds("2026-03-01")).toEqual({ from: "2026-03-01", to: "2026-03-31" });
  });
});
