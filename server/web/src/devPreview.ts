import type { Identity, ProgressPhoto, ProgressPhotoTag, WeightEntry } from "./types";

const tagIds = ["front", "side", "back"] as const;

/** Capture dates spanning roughly fourteen months for local UI preview. */
const captureDates = [
  "2025-06-15",
  "2025-07-20",
  "2025-08-18",
  "2025-09-22",
  "2025-10-14",
  "2025-11-09",
  "2025-12-06",
  "2026-01-12",
  "2026-02-08",
  "2026-03-19",
  "2026-04-25",
  "2026-06-01",
  "2026-07-14",
  "2026-08-08",
];

const firstCapturedAt = "2025-06-15T12:00:00Z";
const latestCapturedAt = "2026-08-08T12:00:00Z";

/** Deterministic identity used only by Vite's local preview mode. */
export const previewIdentity: Identity = {
  email: "preview@pulse.local",
  expires_at: "2099-01-01T00:00:00Z",
};

/** Deterministic tag set used only to present the local UI without private data. */
export const previewTags: ProgressPhotoTag[] = [
  { id: "front", name: "Front", normalized_name: "front", sort_order: 0, created_at: firstCapturedAt, updated_at: latestCapturedAt },
  { id: "side", name: "Side", normalized_name: "side", sort_order: 1, created_at: firstCapturedAt, updated_at: latestCapturedAt },
  { id: "back", name: "Back", normalized_name: "back", sort_order: 2, created_at: firstCapturedAt, updated_at: latestCapturedAt },
];

/** Deterministic photo metadata used only by Vite's local preview mode. */
export const previewPhotos: ProgressPhoto[] = captureDates.flatMap((date, dateIndex) =>
  tagIds.map((tagId) => ({
    id: `preview-${date}-${tagId}`,
    date,
    tag_id: tagId,
    mime: "image/svg+xml",
    bytes: 0,
    sha256: "preview",
    updated_at: `${date}T12:00:00Z`,
  })),
);

export { previewPhotoUrl } from "./lib/previewPhotoUrl";

/** Deterministic downward-trending weight history for preview mode. */
export const previewWeights: WeightEntry[] = captureDates.map((date, index) => ({
  id: `weight-${date}`,
  log_date: date,
  weight_lb: Number((196.2 - index * 1.35).toFixed(1)),
  source_unit: "lb" as const,
  created_at: `${date}T08:00:00Z`,
  updated_at: `${date}T08:00:00Z`,
}));

/** Oldest preview capture date for range-loading demos. */
export const previewRangeFrom = captureDates[0];

/** Newest preview capture date for range-loading demos. */
export const previewRangeTo = captureDates[captureDates.length - 1];
