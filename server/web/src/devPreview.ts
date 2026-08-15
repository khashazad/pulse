import type { Identity, ProgressPhoto, ProgressPhotoTag, WeightEntry } from "./types";

const firstCapturedAt = "2026-01-12T12:00:00Z";
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
export const previewPhotos: ProgressPhoto[] = [
  { id: "demo-front-aug", date: "2026-08-08", tag_id: "front", mime: "image/svg+xml", bytes: 0, sha256: "preview", updated_at: latestCapturedAt },
  { id: "demo-side-aug", date: "2026-08-08", tag_id: "side", mime: "image/svg+xml", bytes: 0, sha256: "preview", updated_at: latestCapturedAt },
  { id: "demo-back-aug", date: "2026-08-08", tag_id: "back", mime: "image/svg+xml", bytes: 0, sha256: "preview", updated_at: latestCapturedAt },
  { id: "demo-front-jan", date: "2026-01-12", tag_id: "front", mime: "image/svg+xml", bytes: 0, sha256: "preview", updated_at: firstCapturedAt },
  { id: "demo-side-jan", date: "2026-01-12", tag_id: "side", mime: "image/svg+xml", bytes: 0, sha256: "preview", updated_at: firstCapturedAt },
  { id: "demo-back-jan", date: "2026-01-12", tag_id: "back", mime: "image/svg+xml", bytes: 0, sha256: "preview", updated_at: firstCapturedAt },
];

/** Deterministic weight history used only by Vite's local preview mode. */
export const previewWeights: WeightEntry[] = [
  { id: "weight-aug", log_date: "2026-08-08", weight_lb: 178.4, source_unit: "lb", created_at: latestCapturedAt, updated_at: latestCapturedAt },
  { id: "weight-jan", log_date: "2026-01-12", weight_lb: 191.8, source_unit: "lb", created_at: firstCapturedAt, updated_at: firstCapturedAt },
];
