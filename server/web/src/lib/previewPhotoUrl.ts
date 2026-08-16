/**
 * Preview art switches to the leaner variant from this date onward so the local
 * timeline reads as visible progress instead of random churn.
 */
const leanerVariantFrom = "2026-03-01";

/**
 * Resolve a generated preview photo id to a bundled demo SVG URL when running locally.
 *
 * @param photoId Generated preview id shaped `preview-<YYYY-MM-DD>-<front|side|back>`.
 * @returns Public demo asset URL whose pose always matches the id's tag, or `null`
 *   when the id was not produced by the preview fixtures.
 */
export function previewPhotoUrl(photoId: string): string | null {
  const match = photoId.match(/^preview-(\d{4}-\d{2}-\d{2})-(front|side|back)$/);
  if (!match) return null;
  const [, date, tag] = match;
  return `/demo/demo-${tag}-${date < leanerVariantFrom ? "jan" : "aug"}.svg`;
}
