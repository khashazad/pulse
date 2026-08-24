import { CalendarDays, Columns2, RefreshCw } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { PhotoTile } from "../../components/PhotoTile";
import { formatDaysAgo, formatLongDate } from "../../lib/date";
import {
  captureDatesNewestFirst,
  captureDatesOldestFirst,
  galleryPhotoOrder,
  groupPhotosByDate,
  previousCaptureDate,
  weightDelta,
} from "../../lib/progress";
import { tagSortOrder } from "../../lib/tags";
import type { ProgressPhoto, ProgressPhotoTag, WeightEntry } from "../../types";
import { PhotoViewer } from "./PhotoViewer";

interface TimelineViewProps {
  photos: ProgressPhoto[];
  tags: ProgressPhotoTag[];
  weights: WeightEntry[];
  token: string;
  selectedTagIds: Set<string> | null;
  loading: boolean;
  loadingEarlier: boolean;
  error?: string;
  highlightDate?: string | null;
  scrollToDate?: string | null;
  onScrollToDateHandled?: () => void;
  onRetry: () => void;
  onLoadEarlier: () => void;
  onCompareFromDate: (date: string) => void;
  onClearHighlight?: () => void;
  onVisibleMonthChange?: (monthKey: string) => void;
}

/** Render gallery skeleton tiles that preserve the final responsive layout. */
function TimelineSkeleton() {
  return (
    <div className="photo-grid" aria-label="Loading progress photos">
      {Array.from({ length: 6 }, (_, index) => (
        <div className="photo-card-skeleton" key={index} />
      ))}
    </div>
  );
}

/** Render the photo-first day feed: date, weight delta, poses, and inline compare. */
export function TimelineView({
  photos,
  tags,
  weights,
  token,
  selectedTagIds,
  loading,
  loadingEarlier,
  error,
  highlightDate,
  scrollToDate,
  onScrollToDateHandled,
  onRetry,
  onLoadEarlier,
  onCompareFromDate,
  onClearHighlight,
  onVisibleMonthChange,
}: TimelineViewProps) {
  const [selectedPhotoId, setSelectedPhotoId] = useState<string | null>(null);
  const [viewerTrigger, setViewerTrigger] = useState<HTMLElement | null>(null);
  const loadEarlierRef = useRef<HTMLDivElement>(null);
  const sectionRefs = useRef<Map<string, HTMLElement>>(new Map());

  const tagOrder = useMemo(() => tagSortOrder(tags), [tags]);
  const groups = useMemo(
    () => groupPhotosByDate(photos, selectedTagIds, tagOrder),
    [photos, selectedTagIds, tagOrder],
  );
  const viewerPhotos = useMemo(
    () => galleryPhotoOrder(photos, selectedTagIds, tagOrder),
    [photos, selectedTagIds, tagOrder],
  );
  const tagNames = useMemo(
    () => new Map(tags.map((tag) => [tag.id, tag.name])),
    [tags],
  );
  const weightsByDate = useMemo(
    () => new Map(weights.map((entry) => [entry.log_date, entry.weight_lb])),
    [weights],
  );
  const captureDatesAsc = useMemo(() => captureDatesOldestFirst(photos), [photos]);

  useEffect(() => {
    if (!scrollToDate) return;
    const section = sectionRefs.current.get(scrollToDate);
    if (section) {
      section.scrollIntoView({ behavior: "smooth", block: "start" });
      onScrollToDateHandled?.();
    }
  }, [onScrollToDateHandled, scrollToDate]);

  useEffect(() => {
    if (!highlightDate) return;
    const timer = window.setTimeout(() => onClearHighlight?.(), 2200);
    return () => window.clearTimeout(timer);
  }, [highlightDate, onClearHighlight]);

  useEffect(() => {
    const node = loadEarlierRef.current;
    if (!node || loadingEarlier) return;
    const prefersReducedMotion =
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (prefersReducedMotion || typeof IntersectionObserver === "undefined") return;

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) onLoadEarlier();
      },
      { rootMargin: "240px" },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [loadingEarlier, onLoadEarlier]);

  useEffect(() => {
    if (!onVisibleMonthChange || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries
          .filter((entry) => entry.isIntersecting)
          .toSorted((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
        const date = visible?.target.getAttribute("data-date");
        if (date) onVisibleMonthChange(date.slice(0, 7));
      },
      { rootMargin: "-15% 0px -70% 0px" },
    );
    for (const section of sectionRefs.current.values()) observer.observe(section);
    return () => observer.disconnect();
  }, [groups, onVisibleMonthChange]);

  /** Open one tile in the shared viewer and remember its focus origin. */
  function openPhoto(photoId: string, trigger: HTMLButtonElement): void {
    setViewerTrigger(trigger);
    setSelectedPhotoId(photoId);
  }

  /** Remember one date section element for calendar and scrubber scrolling. */
  function registerSection(date: string, element: HTMLElement | null): void {
    if (element) sectionRefs.current.set(date, element);
    else sectionRefs.current.delete(date);
  }

  return (
    <section className="timeline-view" aria-label="Progress photo timeline">
      {error && photos.length > 0 ? (
        <div className="inline-notice" role="status">{error}</div>
      ) : null}

      {error && photos.length === 0 ? (
        <div className="state-panel state-panel--error">
          <RefreshCw aria-hidden="true" />
          <h3>Progress is out of reach</h3>
          <p>{error}</p>
          <button type="button" className="button button--primary" onClick={onRetry}>
            Try again
          </button>
        </div>
      ) : loading && photos.length === 0 ? (
        <TimelineSkeleton />
      ) : groups.length === 0 ? (
        <div className="state-panel">
          <CalendarDays aria-hidden="true" />
          <h3>{photos.length === 0 ? "No progress photos yet" : "No photos under these tags"}</h3>
          <p>
            {photos.length === 0
              ? "Photos added from Pulse on iPhone will appear here."
              : "Choose different tags to keep browsing."}
          </p>
        </div>
      ) : (
        <div className="timeline-sections">
          {groups.map((group) => {
            const previousDate = previousCaptureDate(captureDatesAsc, group.date);
            const delta = previousDate ? weightDelta(weightsByDate, previousDate, group.date) : null;
            return (
              <article
                className={`day-card${highlightDate === group.date ? " day-card--highlight" : ""}`}
                key={group.date}
                data-date={group.date}
                ref={(element) => registerSection(group.date, element)}
                aria-label={`Photos from ${formatLongDate(group.date)}`}
              >
                <header className="day-card__head">
                  <div>
                    <div className="day-card__date">{formatLongDate(group.date)}</div>
                    <div className="day-card__relative">{formatDaysAgo(group.date)}</div>
                  </div>
                  {weightsByDate.has(group.date) ? (
                    <div className="day-card__weight">
                      <div className="day-card__weight-value">{weightsByDate.get(group.date)?.toFixed(1)} lb</div>
                      {delta !== null ? (
                        <div className={delta <= 0 ? "day-card__delta day-card__delta--down" : "day-card__delta"}>
                          {delta > 0 ? "+" : ""}
                          {delta.toFixed(1)} lb
                        </div>
                      ) : null}
                    </div>
                  ) : null}
                </header>
                <div className="day-card__photos">
                  {group.photos.map((photo) => (
                    <PhotoTile
                      key={photo.id}
                      photo={photo}
                      tagName={tagNames.get(photo.tag_id) ?? "Progress"}
                      token={token}
                      onOpen={(trigger) => openPhoto(photo.id, trigger)}
                    />
                  ))}
                </div>
                <button
                  type="button"
                  className="day-card__compare"
                  onClick={() => onCompareFromDate(group.date)}
                >
                  <Columns2 aria-hidden="true" size={15} />
                  Compare to earlier photo
                </button>
              </article>
            );
          })}

          <div className="load-earlier" ref={loadEarlierRef}>
            <button
              type="button"
              className="button button--quiet"
              disabled={loadingEarlier}
              onClick={onLoadEarlier}
            >
              {loadingEarlier ? "Loading earlier photos…" : "Load earlier photos"}
            </button>
          </div>
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
