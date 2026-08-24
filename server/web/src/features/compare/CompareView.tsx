import { Scale } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { DatePickerDialog } from "../calendar/CalendarModal";
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
import { monthBounds } from "../../lib/range";
import type { ProgressPhoto, ProgressPhotoTag, WeightEntry } from "../../types";
import { PhotoViewer } from "../gallery/PhotoViewer";
import { ComparePane } from "./ComparePane";

interface CompareViewProps {
  photos: ProgressPhoto[];
  tags: ProgressPhotoTag[];
  weights: WeightEntry[];
  token: string;
  seedLeftDate?: string;
  seedRightDate?: string;
  /**
   * Bumped by the caller on every "compare this day" request. The seed dates
   * are applied once per id, so a later preset or calendar pick sticks instead
   * of being snapped back to the seed on the next render.
   */
  seedRequestId?: number;
  /** Compact desktop side-panel treatment vs. the full mobile screen. */
  variant?: "full" | "tray";
  onEnsureRange?: (from: string, to: string) => void;
}

const PRESETS: Array<{ id: ComparePreset; label: string }> = [
  { id: "first", label: "First" },
  { id: "1y", label: "1y" },
  { id: "6m", label: "6m" },
  { id: "3m", label: "3m" },
  { id: "1m", label: "1m" },
];

/** Render progress comparison with a pose switcher and a draggable onion-skin slider. */
export function CompareView({
  photos,
  tags,
  weights,
  token,
  seedLeftDate,
  seedRightDate,
  seedRequestId,
  variant = "full",
  onEnsureRange,
}: CompareViewProps) {
  const defaults = useMemo(() => defaultComparisonDates(photos), [photos]);
  const datesAsc = useMemo(() => captureDatesOldestFirst(photos), [photos]);
  const latestDate = captureDatesNewestFirst(photos)[0] ?? "";
  const [leftDate, setLeftDate] = useState(defaults?.left ?? "");
  const [rightDate, setRightDate] = useState(defaults?.right ?? "");
  const [activeTagId, setActiveTagId] = useState<string | null>(null);
  const [activeSide, setActiveSide] = useState<"left" | "right" | null>(null);
  const [pickerTrigger, setPickerTrigger] = useState<HTMLElement | null>(null);
  const [selectedPhotoId, setSelectedPhotoId] = useState<string | null>(null);
  const [viewerTrigger, setViewerTrigger] = useState<HTMLElement | null>(null);
  const compareRef = useRef<HTMLElement>(null);
  /** The pose the reader explicitly selected, so date changes do not discard it. */
  const chosenTagRef = useRef<string | null>(null);
  /**
   * The seed request already applied, so a seed never overrides a later pick.
   * Starts below every real id (callers count from 1, and an id-less caller
   * normalizes to 0) so the first seed always lands exactly once.
   */
  const appliedSeedRef = useRef(-1);

  useEffect(() => {
    if (!defaults) return;
    // Apply an incoming seed only once per request. Re-applying it on every
    // render (this effect also watches leftDate) would undo the reader's very
    // next preset or calendar pick.
    const requested = seedRequestId ?? 0;
    if ((seedLeftDate || seedRightDate) && requested !== appliedSeedRef.current) {
      appliedSeedRef.current = requested;
      setLeftDate(seedLeftDate ?? defaults.left);
      setRightDate(seedRightDate ?? defaults.right);
      return;
    }
    if (!leftDate || !rightDate) {
      setLeftDate(defaults.left);
      setRightDate(defaults.right);
    }
  }, [defaults, leftDate, rightDate, seedLeftDate, seedRightDate, seedRequestId]);

  useEffect(() => {
    if (!leftDate || !rightDate || !onEnsureRange) return;
    const from = leftDate < rightDate ? leftDate : rightDate;
    const to = leftDate < rightDate ? rightDate : leftDate;
    onEnsureRange(from, to);
  }, [leftDate, onEnsureRange, rightDate]);

  const rows = useMemo(
    () => comparisonRows(photos, tags, leftDate, rightDate, null),
    [leftDate, photos, rightDate, tags],
  );

  useEffect(() => {
    if (rows.length === 0) {
      setActiveTagId(null);
      return;
    }
    // Keep the reader's chosen pose across a date change, but only while it
    // still has a photo on BOTH sides — holding a pose that can only render
    // "No photo" would be honest and useless. Otherwise fall back to a pose
    // that actually compares, and only then to whatever exists.
    const comparable = (tagId: string): boolean => {
      const row = rows.find((candidate) => candidate.tag.id === tagId);
      return Boolean(row?.left && row?.right);
    };
    const chosen = chosenTagRef.current;
    if (chosen && comparable(chosen)) {
      setActiveTagId(chosen);
      return;
    }
    setActiveTagId((rows.find((row) => row.left && row.right) ?? rows[0]).tag.id);
  }, [rows]);

  useEffect(() => {
    /** Step the focused compare side across adjacent capture dates. */
    function handleKeyDown(event: KeyboardEvent): void {
      if (!compareRef.current?.contains(document.activeElement)) return;
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      const direction = event.key === "ArrowLeft" ? -1 : 1;
      const current = leftDate;
      const next = adjacentCaptureDate(datesAsc, current, direction === -1 ? -1 : 1);
      if (!next) return;
      event.preventDefault();
      setLeftDate(next);
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [datesAsc, leftDate]);

  const activeRow = rows.find((row) => row.tag.id === activeTagId);
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

  /** Open one comparison photo in the shared fullscreen viewer. */
  function openPhoto(photoId: string | undefined, trigger: HTMLElement | null): void {
    if (!photoId) return;
    setViewerTrigger(trigger);
    setSelectedPhotoId(photoId);
  }

  /** Open the calendar picker for one side of the comparison. */
  function openDatePicker(side: "left" | "right"): void {
    setPickerTrigger(compareRef.current);
    setActiveSide(side);
  }

  /** Apply a quick preset to the earlier compare side. */
  function applyPreset(preset: ComparePreset): void {
    const resolved = resolvePresetDate(datesAsc, latestDate, preset);
    if (resolved) setLeftDate(resolved);
    if (latestDate) setRightDate(latestDate);
  }

  if (!defaults) {
    return (
      <section className={`compare-view compare-view--${variant} state-panel`} aria-labelledby="compare-title">
        <Scale aria-hidden="true" />
        <h2 id="compare-title">Nothing to compare yet</h2>
        <p>Add at least one progress photo from Pulse on iPhone.</p>
      </section>
    );
  }

  return (
    <section className={`compare-view compare-view--${variant}`} aria-labelledby="compare-title" ref={compareRef}>
      <h2 id="compare-title" className={variant === "tray" ? "compare-view__title" : "visually-hidden"}>
        Compare
      </h2>

      {rows.length > 0 ? (
        <div className="pose-switcher" role="tablist" aria-label="Compare pose">
          {rows.map((row) => (
            <button
              key={row.tag.id}
              type="button"
              role="tab"
              aria-selected={row.tag.id === activeTagId}
              className={row.tag.id === activeTagId ? "pose-chip pose-chip--active" : "pose-chip"}
              onClick={() => {
                chosenTagRef.current = row.tag.id;
                setActiveTagId(row.tag.id);
              }}
            >
              {row.tag.name}
            </button>
          ))}
        </div>
      ) : null}

      {activeRow ? (
        <div className="compare-pair">
          <ComparePane
            label="Earlier"
            dateLabel={formatShortDate(leftDate)}
            photo={activeRow.left}
            weightLb={leftWeight}
            tagName={activeRow.tag.name}
            token={token}
            onPickDate={() => openDatePicker("left")}
            onOpenPhoto={(trigger) => openPhoto(activeRow.left?.id, trigger)}
          />
          <ComparePane
            label="Later"
            dateLabel={formatShortDate(rightDate)}
            photo={activeRow.right}
            weightLb={rightWeight}
            tagName={activeRow.tag.name}
            token={token}
            onPickDate={() => openDatePicker("right")}
            onOpenPhoto={(trigger) => openPhoto(activeRow.right?.id, trigger)}
          />
        </div>
      ) : (
        <div className="state-panel state-panel--compact">
          <h3>No photos on either day</h3>
          <p>Choose dates from Browse or the calendar.</p>
        </div>
      )}

      <div className="compare-weight-card">
        <div>
          <div className="compare-weight-card__range">
            {leftWeight !== undefined ? leftWeight.toFixed(1) : "—"}
            {" → "}
            {rightWeight !== undefined ? rightWeight.toFixed(1) : "—"} lb
          </div>
          <div className="compare-weight-card__span">
            {daySpan} day{daySpan === 1 ? "" : "s"} apart
          </div>
        </div>
        {delta !== null ? (
          <div className={delta <= 0 ? "compare-weight-card__delta compare-weight-card__delta--down" : "compare-weight-card__delta"}>
            {delta > 0 ? "+" : ""}
            {delta.toFixed(1)} lb
          </div>
        ) : null}
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
