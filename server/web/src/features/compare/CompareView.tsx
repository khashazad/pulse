import { Scale } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { PhotoTile } from "../../components/PhotoTile";
import { formatShortDate } from "../../lib/date";
import { comparisonRows, defaultComparisonDates } from "../../lib/progress";
import type { ProgressPhoto, ProgressPhotoTag, WeightEntry } from "../../types";
import { PhotoViewer } from "../gallery/PhotoViewer";

interface CompareViewProps {
  photos: ProgressPhoto[];
  tags: ProgressPhotoTag[];
  weights: WeightEntry[];
  token: string;
}

interface ComparisonPlaceholderProps {
  tagName: string;
  date: string;
}

/** Render one explicitly labeled gap where a selected day has no matching photo. */
function ComparisonPlaceholder({ tagName, date }: ComparisonPlaceholderProps) {
  return (
    <div
      className="comparison-placeholder"
      aria-label={`No ${tagName} photo on ${formatShortDate(date)}`}
    >
      <span>No photo</span>
    </div>
  );
}

/** Render date-aligned progress photos with one stable row per visible tag. */
export function CompareView({ photos, tags, weights, token }: CompareViewProps) {
  const defaults = useMemo(() => defaultComparisonDates(photos), [photos]);
  const [leftDate, setLeftDate] = useState(defaults?.left ?? "");
  const [rightDate, setRightDate] = useState(defaults?.right ?? "");
  const [selectedPhotoId, setSelectedPhotoId] = useState<string | null>(null);
  const [viewerTrigger, setViewerTrigger] = useState<HTMLElement | null>(null);

  useEffect(() => {
    if (!defaults || (leftDate && rightDate)) return;
    setLeftDate(defaults.left);
    setRightDate(defaults.right);
  }, [defaults, leftDate, rightDate]);

  const rows = useMemo(
    () => comparisonRows(photos, tags, leftDate, rightDate),
    [leftDate, photos, rightDate, tags],
  );
  const viewerPhotos = useMemo(() => {
    const seen = new Set<string>();
    return rows.flatMap((row) => [row.left, row.right]).filter((photo): photo is ProgressPhoto => {
      if (!photo || seen.has(photo.id)) return false;
      seen.add(photo.id);
      return true;
    });
  }, [rows]);
  const weightsByDate = useMemo(
    () => new Map(weights.map((entry) => [entry.log_date, entry.weight_lb])),
    [weights],
  );

  /** Open one comparison tile in the shared fullscreen viewer. */
  function openPhoto(photoId: string, trigger: HTMLButtonElement): void {
    setViewerTrigger(trigger);
    setSelectedPhotoId(photoId);
  }

  if (!defaults) {
    return (
      <section className="compare-view state-panel" aria-labelledby="compare-title">
        <Scale aria-hidden="true" />
        <h2 id="compare-title">Nothing to compare yet</h2>
        <p>Add at least one progress photo from Pulse on iPhone.</p>
      </section>
    );
  }

  return (
    <section className="compare-view" aria-labelledby="compare-title">
      <div className="section-heading">
        <div>
          <span className="eyebrow">Then and now</span>
          <h2 id="compare-title">Compare your progress</h2>
        </div>
      </div>

      <div className="date-pickers">
        <label>
          <span>Earlier date</span>
          <input
            type="date"
            aria-label="Earlier date"
            value={leftDate}
            max={rightDate}
            onChange={(event) => setLeftDate(event.target.value)}
          />
          {weightsByDate.has(leftDate) ? (
            <small>{weightsByDate.get(leftDate)?.toFixed(1)} lb</small>
          ) : null}
        </label>
        <span className="date-pickers__divider" aria-hidden="true" />
        <label>
          <span>Later date</span>
          <input
            type="date"
            aria-label="Later date"
            value={rightDate}
            min={leftDate}
            onChange={(event) => setRightDate(event.target.value)}
          />
          {weightsByDate.has(rightDate) ? (
            <small>{weightsByDate.get(rightDate)?.toFixed(1)} lb</small>
          ) : null}
        </label>
      </div>

      {rows.length === 0 ? (
        <div className="state-panel state-panel--compact">
          <h3>No photos on either day</h3>
          <p>Choose dates from your visual timeline.</p>
        </div>
      ) : (
        <div className="comparison-rows">
          {rows.map((row) => (
            <article className="comparison-row" key={row.tag.id}>
              <h3>{row.tag.name}</h3>
              <div className="comparison-pair">
                {row.left ? (
                  <PhotoTile
                    photo={row.left}
                    tagName={row.tag.name}
                    weightLb={weightsByDate.get(leftDate)}
                    token={token}
                    onOpen={(trigger) => openPhoto(row.left!.id, trigger)}
                  />
                ) : (
                  <ComparisonPlaceholder tagName={row.tag.name} date={leftDate} />
                )}
                {row.right ? (
                  <PhotoTile
                    photo={row.right}
                    tagName={row.tag.name}
                    weightLb={weightsByDate.get(rightDate)}
                    token={token}
                    onOpen={(trigger) => openPhoto(row.right!.id, trigger)}
                  />
                ) : (
                  <ComparisonPlaceholder tagName={row.tag.name} date={rightDate} />
                )}
              </div>
            </article>
          ))}
        </div>
      )}

      {selectedPhotoId ? (
        <PhotoViewer
          photos={viewerPhotos}
          selectedId={selectedPhotoId}
          tags={tags}
          token={token}
          onSelect={setSelectedPhotoId}
          onClose={() => setSelectedPhotoId(null)}
          restoreFocusTo={viewerTrigger}
        />
      ) : null}
    </section>
  );
}
