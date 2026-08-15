import { describe, expect, test, vi } from "vitest";

import { HttpError } from "./http";
import { listPhotos, listPhotoTags, listWeights, loadPhotoBlob } from "./pulse";

/** Return a successful JSON response for API-client tests. */
function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("Pulse web API", () => {
  test("sends the Bearer token when listing tags", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(jsonResponse([]));

    await listPhotoTags("token", undefined, fetcher);

    expect(fetcher).toHaveBeenCalledWith(
      "/measures/photo-tags",
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: "Bearer token" }),
      }),
    );
  });

  test("encodes inclusive metadata and weight ranges", async () => {
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async () => jsonResponse([]));

    await listPhotos("token", "2026-01-01", "2026-08-13", undefined, fetcher);
    await listWeights("token", "2026-01-01", "2026-08-13", undefined, fetcher);

    expect(fetcher.mock.calls[0][0]).toBe(
      "/measures/photos?from=2026-01-01&to=2026-08-13",
    );
    expect(fetcher.mock.calls[1][0]).toBe("/weight?from=2026-01-01&to=2026-08-13");
  });

  test("downloads an authorized photo blob at the requested size", async () => {
    const blob = new Blob(["jpeg"], { type: "image/jpeg" });
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(new Response(blob));

    await expect(loadPhotoBlob("token", "photo-id", "full", undefined, fetcher)).resolves.toEqual(
      blob,
    );
    expect(fetcher).toHaveBeenCalledWith(
      "/measures/photos/photo-id?size=full",
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: "Bearer token" }),
      }),
    );
  });

  test("normalizes unauthorized responses into an HttpError", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(
      jsonResponse({ detail: "unauthorized" }, 401),
    );

    await expect(listPhotoTags("bad-token", undefined, fetcher)).rejects.toMatchObject({
      status: 401,
      message: "unauthorized",
    } satisfies Partial<HttpError>);
  });
});
