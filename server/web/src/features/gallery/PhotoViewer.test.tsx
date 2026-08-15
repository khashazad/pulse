import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import type { ProgressPhoto, ProgressPhotoTag } from "../../types";
import { PhotoViewer } from "./PhotoViewer";

const tag: ProgressPhotoTag = {
  id: "front",
  name: "Front",
  normalized_name: "front",
  sort_order: 0,
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
};

/** Build a viewer photo fixture. */
function photo(id: string, date: string): ProgressPhoto {
  return {
    id,
    date,
    tag_id: "front",
    mime: "image/jpeg",
    bytes: 100,
    sha256: `sha-${id}`,
    updated_at: `${date}T12:00:00Z`,
  };
}

describe("PhotoViewer", () => {
  beforeEach(() => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation(
        async () => new Response(new Blob(["jpeg"], { type: "image/jpeg" })),
      ),
    );
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: vi.fn(() => "blob:full"),
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      configurable: true,
      value: vi.fn(),
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  test("navigates with keyboard arrows and exposes visible controls", () => {
    const onSelect = vi.fn();
    const photos = [photo("new", "2026-08-01"), photo("old", "2026-06-01")];
    render(
      <PhotoViewer
        photos={photos}
        selectedId="new"
        tags={[tag]}
        token="token"
        onSelect={onSelect}
        onClose={vi.fn()}
      />,
    );

    expect(screen.getByText("Aug 1, 2026")).toBeVisible();
    expect(screen.getByRole("button", { name: "Previous photo" })).toBeDisabled();
    fireEvent.keyDown(window, { key: "ArrowRight" });
    expect(onSelect).toHaveBeenCalledWith("old");
    fireEvent.click(screen.getByRole("button", { name: "Next photo" }));
    expect(onSelect).toHaveBeenCalledWith("old");
  });
});
