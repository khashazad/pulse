import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import { useAuthorizedImage } from "./useAuthorizedImage";

describe("useAuthorizedImage", () => {
  beforeEach(() => {
    vi.stubGlobal("fetch", vi.fn());
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: vi.fn(() => "blob:pulse-photo"),
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      configurable: true,
      value: vi.fn(),
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  test("creates and revokes an object URL for an authorized image", async () => {
    vi.mocked(fetch).mockResolvedValue(
      new Response(new Blob(["jpeg"], { type: "image/jpeg" })),
    );
    const { result, unmount } = renderHook(() =>
      useAuthorizedImage("token", "photo-id", "thumb"),
    );

    await waitFor(() => expect(result.current.url).toBe("blob:pulse-photo"));
    expect(fetch).toHaveBeenCalledWith(
      "/measures/photos/photo-id?size=thumb",
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: "Bearer token" }),
      }),
    );

    unmount();
    expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:pulse-photo");
  });

  test("aborts a stale image request when the photo changes", async () => {
    const signals: AbortSignal[] = [];
    vi.mocked(fetch).mockImplementation(
      async (_input, init) =>
        await new Promise<Response>((resolve) => {
          if (init?.signal) signals.push(init.signal);
          void resolve;
        }),
    );
    const { rerender } = renderHook(
      ({ photoId }) => useAuthorizedImage("token", photoId, "thumb"),
      { initialProps: { photoId: "first" } },
    );

    await waitFor(() => expect(signals).toHaveLength(1));
    act(() => rerender({ photoId: "second" }));
    await waitFor(() => expect(signals).toHaveLength(2));

    expect(signals[0].aborted).toBe(true);
    expect(signals[1].aborted).toBe(false);
  });
});
