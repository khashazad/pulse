import type { ProgressPhoto, ProgressPhotoTag, WeightEntry } from "../types";
import { requestBlob, requestJson } from "./http";

/** Build one inclusive date-range query using the server's wire names. */
function rangePath(path: string, from: string, to: string): string {
  return `${path}?${new URLSearchParams({ from, to }).toString()}`;
}

/** List the authenticated user's ordered progress-photo tags. */
export function listPhotoTags(
  token: string,
  signal?: AbortSignal,
  fetcher: typeof fetch = fetch,
): Promise<ProgressPhotoTag[]> {
  return requestJson("/measures/photo-tags", token, { signal }, fetcher);
}

/** List progress-photo metadata in an inclusive calendar range. */
export function listPhotos(
  token: string,
  from: string,
  to: string,
  signal?: AbortSignal,
  fetcher: typeof fetch = fetch,
): Promise<ProgressPhoto[]> {
  return requestJson(rangePath("/measures/photos", from, to), token, { signal }, fetcher);
}

/** List body weights in an inclusive calendar range. */
export function listWeights(
  token: string,
  from: string,
  to: string,
  signal?: AbortSignal,
  fetcher: typeof fetch = fetch,
): Promise<WeightEntry[]> {
  return requestJson(rangePath("/weight", from, to), token, { signal }, fetcher);
}

/** Download an authorized progress-photo image variant. */
export function loadPhotoBlob(
  token: string,
  photoId: string,
  size: "thumb" | "full",
  signal?: AbortSignal,
  fetcher: typeof fetch = fetch,
): Promise<Blob> {
  const query = new URLSearchParams({ size });
  return requestBlob(`/measures/photos/${encodeURIComponent(photoId)}?${query}`, token, signal, fetcher);
}
