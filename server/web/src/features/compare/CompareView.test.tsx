import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import type { ProgressPhoto, ProgressPhotoTag, WeightEntry } from "../../types";
import { CompareView } from "./CompareView";

const tags: ProgressPhotoTag[] = [
  {
    id: "front",
    name: "Front",
    normalized_name: "front",
    sort_order: 0,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  },
  {
    id: "side",
    name: "Side",
    normalized_name: "side",
    sort_order: 1,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  },
];

/** Build a comparison photo fixture. */
function photo(id: string, date: string, tagId: string): ProgressPhoto {
  return {
    id,
    date,
    tag_id: tagId,
    mime: "image/jpeg",
    bytes: 100,
    sha256: `sha-${id}`,
    updated_at: `${date}T12:00:00Z`,
  };
}

const photos = [
  photo("old-front", "2026-06-01", "front"),
  photo("new-front", "2026-08-01", "front"),
  photo("new-side", "2026-08-01", "side"),
  photo("middle-side", "2026-07-01", "side"),
];

const weights: WeightEntry[] = [
  {
    id: "weight-old",
    log_date: "2026-07-01",
    weight_lb: 190,
    source_unit: "lb",
    created_at: "2026-07-01T12:00:00Z",
    updated_at: "2026-07-01T12:00:00Z",
  },
  {
    id: "weight-new",
    log_date: "2026-08-01",
    weight_lb: 182.4,
    source_unit: "lb",
    created_at: "2026-08-01T12:00:00Z",
    updated_at: "2026-08-01T12:00:00Z",
  },
];

describe("CompareView", () => {
  beforeEach(() => {
    localStorage.clear();
    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation(
        async () => new Response(new Blob(["jpeg"], { type: "image/jpeg" })),
      ),
    );
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: vi.fn(() => "blob:photo"),
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      configurable: true,
      value: vi.fn(),
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  test("defaults to the two newest photo dates and shows the weight delta", () => {
    render(
      <CompareView photos={photos} tags={tags} weights={weights} token="token" />,
    );

    expect(screen.getByLabelText("Choose earlier date")).toHaveTextContent("Jul 1, 2026");
    expect(screen.getByLabelText("Choose later date")).toHaveTextContent("Aug 1, 2026");
    expect(screen.getByText("-7.6 lb")).toBeVisible();
    expect(screen.getByText("31 days apart")).toBeVisible();
    expect(screen.getByRole("heading", { name: "Side" })).toBeVisible();
  });

  test("applies a quick preset to the earlier side", () => {
    render(
      <CompareView photos={photos} tags={tags} weights={weights} token="token" />,
    );

    fireEvent.click(screen.getByRole("button", { name: "First" }));
    expect(screen.getByLabelText("Choose earlier date")).toHaveTextContent("Jun 1, 2026");
    expect(screen.getByRole("button", { name: "Open Front progress photo from Jun 1, 2026" })).toBeVisible();
  });

  test("opens the calendar date picker for the earlier side", () => {
    render(
      <CompareView photos={photos} tags={tags} weights={weights} token="token" />,
    );

    fireEvent.click(screen.getByLabelText("Choose earlier date"));
    expect(screen.getByRole("dialog", { name: "Choose earlier date" })).toBeVisible();
  });

  test("opens either side in the shared viewer", () => {
    render(
      <CompareView photos={photos} tags={tags} weights={weights} token="token" />,
    );

    fireEvent.click(
      screen.getByRole("button", { name: "Open Side progress photo from Jul 1, 2026" }),
    );
    expect(screen.getByRole("dialog", { name: "Progress photo viewer" })).toBeVisible();
  });
});
