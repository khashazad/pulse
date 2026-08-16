import { CalendarDays, Columns2, RefreshCw } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { TagChipFilter } from "../../components/TagChipFilter";
import { PhotoTile } from "../../components/PhotoTile";
import { useTagSelection } from "../../hooks/useTagSelection";
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
}

/** Render gallery skeleton tiles that preserve the final responsive layout. */
function TimelineSkeleton() {
  return (
    <div className="photo-grid photo-grid--feature" aria-label="Loading progress photos">
      {Array.from({ length: 6 }, (_, index) => (
        <div className="photo-card-skeleton" key={index} />
      ))}
    </div>
  );
}

/** Render the photo-first timeline with status, tags, and date sections. */
export function TimelineView({
  photos,
  tags,
  weights,
  token,
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
}: TimelineViewProps) {
  const { selectedTagIds, selectAll, toggleTag } = useTagSelection(tags.map((tag) => tag.id));
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
  const latestDate = captureDatesNewestFirst(photos)[0];
  const previousDate = latestDate ? previousCaptureDate(captureDatesAsc, latestDate) : null;
  const latestWeight = latestDate ? weightsByDate.get(latestDate) : undefined;
  const previousWeight = previousDate ? weightsByDate.get(previousDate) : undefined;
  const latestDelta =
    latestDate && previousDate
      ? weightDelta(weightsByDate, previousDate, latestDate)
      : null;

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

  /** Open one tile in the shared viewer and remember its focus origin. */
  function openPhoto(photoId: string, trigger: HTMLButtonElement): void {
    setViewerTrigger(trigger);
    setSelectedPhotoId(photoId);
  }

  /** Remember one date section element for calendar scrolling. */
  function registerSection(date: string, element: HTMLElement | null): void {
    if (element) sectionRefs.current.set(date, element);
    else sectionRefs.current.delete(date);
  }

  const [featureGroup, ...olderGroups] = groups;

  return (
    <section className="timeline-view" aria-label="Progress photo timeline">
      {latestDate ? (
        <div className="timeline-status">
          <div className="timeline-status__primary">
            <strong>{formatLongDate(latestDate)}</strong>
            {latestWeight !== undefined ? (
              <span className="timeline-status__weight">{latestWeight.toFixed(1)} lb</span>
            ) : null}
            {latestDelta !== null ? (
              <span
                className={
                  latestDelta <= 0 ? "timeline-status__delta timeline-status__delta--down" : "timeline-status__delta"
                }
              >
                {latestDelta > 0 ? "+" : ""}
                {latestDelta.toFixed(1)} lb vs previous
              </span>
            ) : null}
          </div>
          <button
            type="button"
            className="button button--quiet timeline-status__compare"
            onClick={() => onCompareFromDate(latestDate)}
          >
            Compare to…
          </button>
        </div>
      ) : null}

      {tags.length > 0 ? (
        <TagChipFilter
          tags={tags}
          selectedTagIds={selectedTagIds}
          onToggle={toggleTag}
          onSelectAll={selectAll}
        />
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
          {featureGroup ? (
            <section
              className={`date-group date-group--feature${highlightDate === featureGroup.date ? " date-group--highlight" : ""}`}
              key={featureGroup.date}
              ref={(element) => registerSection(featureGroup.date, element)}
              aria-label={`Photos from ${formatLongDate(featureGroup.date)}`}
            >
              <header className="date-group__header">
                <div>
                  <h2>{formatLongDate(featureGroup.date)}</h2>
                  <span className="date-group__meta">
                    {formatDaysAgo(featureGroup.date)}
                    {weightsByDate.has(featureGroup.date)
                      ? ` · ${weightsByDate.get(featureGroup.date)?.toFixed(1)} lb`
                      : ""}
                  </span>
                </div>
                <button
                  type="button"
                  className="button button--quiet date-group__compare"
                  aria-label={`Compare ${formatLongDate(featureGroup.date)}`}
                  onClick={() => onCompareFromDate(featureGroup.date)}
                >
                  <Columns2 aria-hidden="true" size={14} />
                  Compare
                </button>
              </header>
              <div className="photo-grid photo-grid--feature">
                {featureGroup.photos.map((photo) => (
                  <PhotoTile
                    key={photo.id}
                    photo={photo}
                    tagName={tagNames.get(photo.tag_id) ?? "Progress"}
                    weightLb={weightsByDate.get(featureGroup.date)}
                    token={token}
                    onOpen={(trigger) => openPhoto(photo.id, trigger)}
                  />
                ))}
              </div>
            </section>
          ) : null}

          {olderGroups.map((group) => (
            <section
              className={`date-group${highlightDate === group.date ? " date-group--highlight" : ""}`}
              key={group.date}
              ref={(element) => registerSection(group.date, element)}
              aria-label={`Photos from ${formatLongDate(group.date)}`}
            >
              <header className="date-group__header">
                <div>
                  <h3>{formatLongDate(group.date)}</h3>
                  <span className="date-group__meta">
                    {formatDaysAgo(group.date)}
                    {weightsByDate.has(group.date)
                      ? ` · ${weightsByDate.get(group.date)?.toFixed(1)} lb`
                      : ""}
                  </span>
                </div>
                <button
                  type="button"
                  className="button button--quiet date-group__compare"
                  aria-label={`Compare ${formatLongDate(group.date)}`}
                  onClick={() => onCompareFromDate(group.date)}
                >
                  <Columns2 aria-hidden="true" size={14} />
                  Compare
                </button>
              </header>
              <div className="photo-grid">
                {group.photos.map((photo) => (
                  <PhotoTile
                    key={photo.id}
                    photo={photo}
                    tagName={tagNames.get(photo.tag_id) ?? "Progress"}
                    weightLb={weightsByDate.get(group.date)}
                    token={token}
                    onOpen={(trigger) => openPhoto(photo.id, trigger)}
                  />
                ))}
              </div>
            </section>
          ))}

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
