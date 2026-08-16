import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import type { ProgressPhoto } from "../types";
import { PhotoTile } from "./PhotoTile";

const photo: ProgressPhoto = {
  id: "photo-id",
  date: "2026-08-01",
  tag_id: "front",
  mime: "image/jpeg",
  bytes: 1024,
  sha256: "sha",
  updated_at: "2026-08-01T12:00:00Z",
};

describe("PhotoTile", () => {
  beforeEach(() => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(new Response(new Blob(["jpeg"], { type: "image/jpeg" }))),
    );
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: vi.fn(() => "blob:thumb"),
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      configurable: true,
      value: vi.fn(),
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  test("renders an authorized full image and opens from its accessible button", async () => {
    const onOpen = vi.fn();
    render(
      <PhotoTile
        photo={photo}
        tagName="Front"
        weightLb={182.4}
        token="token"
        onOpen={onOpen}
      />,
    );

    const button = screen.getByRole("button", {
      name: "Open Front progress photo from Aug 1, 2026",
    });
    await waitFor(() => expect(screen.getByRole("img", { name: /Front progress/ })).toBeVisible());
    expect(fetch).toHaveBeenCalledWith(
      "/measures/photos/photo-id?size=full",
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: "Bearer token" }),
      }),
    );
    expect(screen.getByText("182.4 lb")).toBeVisible();

    fireEvent.click(button);
    expect(onOpen).toHaveBeenCalledWith(button);
  });

  test("keeps a failed image local to the tile", async () => {
    vi.mocked(fetch).mockResolvedValue(new Response("broken", { status: 500 }));
    render(
      <PhotoTile photo={photo} tagName="Front" token="token" onOpen={vi.fn()} />,
    );

    await waitFor(() => expect(screen.getByText("Image unavailable")).toBeVisible());
  });
});
