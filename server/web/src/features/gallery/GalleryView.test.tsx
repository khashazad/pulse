import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import type { ProgressPhoto, ProgressPhotoTag, WeightEntry } from "../../types";
import { GalleryView } from "./GalleryView";

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

/** Build a concise gallery photo fixture. */
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
  photo("front-new", "2026-08-01", "front"),
  photo("side-new", "2026-08-01", "side"),
  photo("front-old", "2026-06-01", "front"),
];

const weights: WeightEntry[] = [
  {
    id: "weight",
    log_date: "2026-08-01",
    weight_lb: 182.4,
    source_unit: "lb",
    created_at: "2026-08-01T12:00:00Z",
    updated_at: "2026-08-01T12:00:00Z",
  },
];

describe("GalleryView", () => {
  beforeEach(() => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation(
        async () => new Response(new Blob(["jpeg"], { type: "image/jpeg" })),
      ),
    );
    let objectId = 0;
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: vi.fn(() => `blob:photo-${++objectId}`),
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      configurable: true,
      value: vi.fn(),
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  test("filters the grouped gallery by tag", () => {
    render(
      <GalleryView
        photos={photos}
        tags={tags}
        weights={weights}
        token="token"
        loading={false}
        onRetry={vi.fn()}
        onLoadEarlier={vi.fn()}
      />,
    );

    expect(screen.getAllByRole("button", { name: /Open .* progress photo/ })).toHaveLength(3);
    fireEvent.click(screen.getByRole("button", { name: "Filter by Side" }));
    expect(screen.getAllByRole("button", { name: /Open .* progress photo/ })).toHaveLength(1);
    expect(screen.getByRole("heading", { name: "Saturday, August 1, 2026" })).toBeVisible();
  });

  test("opens the fullscreen viewer and restores focus when it closes", async () => {
    render(
      <GalleryView
        photos={photos}
        tags={tags}
        weights={weights}
        token="token"
        loading={false}
        onRetry={vi.fn()}
        onLoadEarlier={vi.fn()}
      />,
    );
    const tile = screen.getByRole("button", {
      name: "Open Front progress photo from Aug 1, 2026",
    });

    fireEvent.click(tile);
    expect(screen.getByRole("dialog", { name: "Progress photo viewer" })).toBeVisible();
    fireEvent.keyDown(window, { key: "Escape" });

    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    expect(tile).toHaveFocus();
  });

  test("renders retry and load-earlier actions", () => {
    const onRetry = vi.fn();
    const onLoadEarlier = vi.fn();
    const { rerender } = render(
      <GalleryView
        photos={[]}
        tags={tags}
        weights={[]}
        token="token"
        loading={false}
        error="Could not load progress photos."
        onRetry={onRetry}
        onLoadEarlier={onLoadEarlier}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(onRetry).toHaveBeenCalledOnce();

    rerender(
      <GalleryView
        photos={photos}
        tags={tags}
        weights={weights}
        token="token"
        loading={false}
        onRetry={onRetry}
        onLoadEarlier={onLoadEarlier}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: "Load earlier photos" }));
    expect(onLoadEarlier).toHaveBeenCalledOnce();
  });
});
