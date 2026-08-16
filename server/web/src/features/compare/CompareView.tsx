import { Scale } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { TagChipFilter } from "../../components/TagChipFilter";
import { PhotoTile } from "../../components/PhotoTile";
import { DatePickerDialog } from "../calendar/CalendarModal";
import { useTagSelection } from "../../hooks/useTagSelection";
import { daysBetween, formatShortDate } from "../../lib/date";
import {
  adjacentCaptureDate,
  captureDatesNewestFirst,
  captureDatesOldestFirst,
  comparisonRows,
  defaultComparisonDates,
  resolvePresetDate,
  type ComparePreset,
  weightDelta,
} from "../../lib/progress";
import { commonTagsForDates } from "../../lib/tags";
import { monthBounds } from "../../lib/range";
import type { ProgressPhoto, ProgressPhotoTag, WeightEntry } from "../../types";
import { PhotoViewer } from "../gallery/PhotoViewer";

interface CompareViewProps {
  photos: ProgressPhoto[];
  tags: ProgressPhotoTag[];
  weights: WeightEntry[];
  token: string;
  seedLeftDate?: string;
  seedRightDate?: string;
  onEnsureRange?: (from: string, to: string) => void;
}

interface ComparisonPlaceholderProps {
  tagName: string;
  date: string;
}

const PRESETS: Array<{ id: ComparePreset; label: string }> = [
  { id: "first", label: "First" },
  { id: "1y", label: "1y ago" },
  { id: "6m", label: "6m ago" },
  { id: "3m", label: "3m ago" },
  { id: "1m", label: "1m ago" },
];

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

/** Render side-by-side progress comparisons with calendar-based date selection. */
export function CompareView({
  photos,
  tags,
  weights,
  token,
  seedLeftDate,
  seedRightDate,
  onEnsureRange,
}: CompareViewProps) {
  const defaults = useMemo(() => defaultComparisonDates(photos), [photos]);
  const datesAsc = useMemo(() => captureDatesOldestFirst(photos), [photos]);
  const latestDate = captureDatesNewestFirst(photos)[0] ?? "";
  const [leftDate, setLeftDate] = useState(defaults?.left ?? "");
  const [rightDate, setRightDate] = useState(defaults?.right ?? "");
  const [activeSide, setActiveSide] = useState<"left" | "right" | null>(null);
  const [pickerTrigger, setPickerTrigger] = useState<HTMLElement | null>(null);
  const [selectedPhotoId, setSelectedPhotoId] = useState<string | null>(null);
  const [viewerTrigger, setViewerTrigger] = useState<HTMLElement | null>(null);
  const compareRef = useRef<HTMLElement>(null);
  const commonTags = useMemo(
    () => (leftDate && rightDate ? commonTagsForDates(photos, leftDate, rightDate) : new Set<string>()),
    [leftDate, photos, rightDate],
  );
  const { selectedTagIds, selectAll, toggleTag } = useTagSelection(tags.map((tag) => tag.id));
  const effectiveTagFilter = useMemo(() => {
    if (selectedTagIds && selectedTagIds.size > 0) return selectedTagIds;
    return commonTags.size > 0 ? commonTags : null;
  }, [commonTags, selectedTagIds]);

  useEffect(() => {
    if (!defaults) return;
    if (seedLeftDate || seedRightDate) {
      setLeftDate(seedLeftDate ?? defaults.left);
      setRightDate(seedRightDate ?? defaults.right);
      return;
    }
    if (!leftDate || !rightDate) {
      setLeftDate(defaults.left);
      setRightDate(defaults.right);
    }
  }, [defaults, leftDate, rightDate, seedLeftDate, seedRightDate]);

  useEffect(() => {
    if (!leftDate || !rightDate || !onEnsureRange) return;
    const from = leftDate < rightDate ? leftDate : rightDate;
    const to = leftDate < rightDate ? rightDate : leftDate;
    onEnsureRange(from, to);
  }, [leftDate, onEnsureRange, rightDate]);

  useEffect(() => {
    /** Step the focused compare side across adjacent capture dates. */
    function handleKeyDown(event: KeyboardEvent): void {
      if (!compareRef.current?.contains(document.activeElement)) return;
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      const direction = event.key === "ArrowLeft" ? -1 : 1;
      const side = activeSide ?? "left";
      const current = side === "left" ? leftDate : rightDate;
      const next = adjacentCaptureDate(datesAsc, current, direction === -1 ? -1 : 1);
      if (!next) return;
      event.preventDefault();
      if (side === "left") setLeftDate(next);
      else setRightDate(next);
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [activeSide, datesAsc, leftDate, rightDate]);

  const rows = useMemo(
    () => comparisonRows(photos, tags, leftDate, rightDate, effectiveTagFilter),
    [effectiveTagFilter, leftDate, photos, rightDate, tags],
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
  const leftWeight = weightsByDate.get(leftDate);
  const rightWeight = weightsByDate.get(rightDate);
  const delta = weightDelta(weightsByDate, leftDate, rightDate);
  const daySpan = leftDate && rightDate ? daysBetween(leftDate, rightDate) : 0;

  /** Open one comparison tile in the shared fullscreen viewer. */
  function openPhoto(photoId: string, trigger: HTMLButtonElement): void {
    setViewerTrigger(trigger);
    setSelectedPhotoId(photoId);
  }

  /** Apply a quick preset to the earlier compare side. */
  function applyPreset(preset: ComparePreset): void {
    const resolved = resolvePresetDate(datesAsc, latestDate, preset);
    if (resolved) setLeftDate(resolved);
    if (latestDate) setRightDate(latestDate);
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
    <section className="compare-view" aria-labelledby="compare-title" ref={compareRef}>
      <h2 id="compare-title" className="visually-hidden">
        Compare progress
      </h2>

      <div className="compare-header">
        <div className="compare-header__side">
          <button
            type="button"
            className="compare-date-button"
            aria-label="Choose earlier date"
            onClick={(event) => {
              setPickerTrigger(event.currentTarget);
              setActiveSide("left");
            }}
          >
            <span className="compare-date-button__label">Earlier</span>
            <strong>{formatShortDate(leftDate)}</strong>
            {leftWeight !== undefined ? <small>{leftWeight.toFixed(1)} lb</small> : null}
          </button>
        </div>

        <div className="compare-header__middle" aria-live="polite">
          {delta !== null ? (
            <strong className={delta <= 0 ? "compare-header__delta compare-header__delta--down" : "compare-header__delta"}>
              {delta > 0 ? "+" : ""}
              {delta.toFixed(1)} lb
            </strong>
          ) : (
            <strong className="compare-header__delta compare-header__delta--muted">—</strong>
          )}
          <span>
            {daySpan} day{daySpan === 1 ? "" : "s"} apart
          </span>
        </div>

        <div className="compare-header__side">
          <button
            type="button"
            className="compare-date-button"
            aria-label="Choose later date"
            onClick={(event) => {
              setPickerTrigger(event.currentTarget);
              setActiveSide("right");
            }}
          >
            <span className="compare-date-button__label">Later</span>
            <strong>{formatShortDate(rightDate)}</strong>
            {rightWeight !== undefined ? <small>{rightWeight.toFixed(1)} lb</small> : null}
          </button>
        </div>
      </div>

      <div className="compare-presets" role="toolbar" aria-label="Quick compare presets">
        {PRESETS.map((preset) => (
          <button
            key={preset.id}
            type="button"
            className="tag-chip"
            onClick={() => applyPreset(preset.id)}
          >
            {preset.label}
          </button>
        ))}
      </div>

      {tags.length > 0 ? (
        <TagChipFilter
          tags={tags}
          selectedTagIds={selectedTagIds}
          onToggle={toggleTag}
          onSelectAll={selectAll}
        />
      ) : null}

      {rows.length === 0 ? (
        <div className="state-panel state-panel--compact">
          <h3>No photos on either day</h3>
          <p>Choose dates from your timeline or adjust tag filters.</p>
        </div>
      ) : (
        <div className="comparison-rows">
          {rows.map((row) => (
            <article className="comparison-row" key={row.tag.id}>
              <h3>{row.tag.name}</h3>
              <div className="comparison-pair comparison-pair--large">
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

      {activeSide ? (
        <DatePickerDialog
          open
          photos={photos}
          token={token}
          selectedDate={activeSide === "left" ? leftDate : rightDate}
          title={activeSide === "left" ? "Choose earlier date" : "Choose later date"}
          restoreFocusTo={pickerTrigger}
          onClose={() => setActiveSide(null)}
          onSelectDate={(date) => {
            if (activeSide === "left") setLeftDate(date);
            else setRightDate(date);
            setActiveSide(null);
          }}
          onMonthChange={(monthAnchor) => {
            const bounds = monthBounds(monthAnchor);
            onEnsureRange?.(bounds.from, bounds.to);
          }}
        />
      ) : null}

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
