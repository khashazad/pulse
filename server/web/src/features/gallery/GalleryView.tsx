import { CalendarDays, RefreshCw } from "lucide-react";
import { useMemo, useState } from "react";

import { PhotoTile } from "../../components/PhotoTile";
import { TagFilter } from "../../components/TagFilter";
import { formatLongDate } from "../../lib/date";
import { galleryPhotoOrder, groupPhotosByDate } from "../../lib/progress";
import type { ProgressPhoto, ProgressPhotoTag, WeightEntry } from "../../types";
import { PhotoViewer } from "./PhotoViewer";

interface GalleryViewProps {
  photos: ProgressPhoto[];
  tags: ProgressPhotoTag[];
  weights: WeightEntry[];
  token: string;
  loading: boolean;
  error?: string;
  onRetry: () => void;
  onLoadEarlier: () => void;
}

/** Render gallery skeleton tiles that preserve the final responsive layout. */
function GallerySkeleton() {
  return (
    <div className="photo-grid" aria-label="Loading progress photos">
      {Array.from({ length: 8 }, (_, index) => (
        <div className="photo-card-skeleton" key={index} />
      ))}
    </div>
  );
}

/** Render the date-grouped, tag-filterable progress-photo gallery. */
export function GalleryView({
  photos,
  tags,
  weights,
  token,
  loading,
  error,
  onRetry,
  onLoadEarlier,
}: GalleryViewProps) {
  const [selectedTagId, setSelectedTagId] = useState<string | null>(null);
  const [selectedPhotoId, setSelectedPhotoId] = useState<string | null>(null);
  const [viewerTrigger, setViewerTrigger] = useState<HTMLElement | null>(null);
  const groups = useMemo(
    () => groupPhotosByDate(photos, selectedTagId),
    [photos, selectedTagId],
  );
  const viewerPhotos = useMemo(
    () => galleryPhotoOrder(photos, selectedTagId),
    [photos, selectedTagId],
  );
  const tagNames = useMemo(
    () => new Map(tags.map((tag) => [tag.id, tag.name])),
    [tags],
  );
  const weightsByDate = useMemo(
    () => new Map(weights.map((entry) => [entry.log_date, entry.weight_lb])),
    [weights],
  );

  /** Open one tile in the shared viewer and remember its focus origin. */
  function openPhoto(photoId: string, trigger: HTMLButtonElement): void {
    setViewerTrigger(trigger);
    setSelectedPhotoId(photoId);
  }

  return (
    <section className="gallery-view" aria-labelledby="gallery-title">
      <div className="section-heading">
        <div>
          <span className="eyebrow">Visual timeline</span>
          <h2 id="gallery-title">Your progression</h2>
        </div>
        <span className="photo-count">{photos.length} photos</span>
      </div>

      {tags.length > 0 ? (
        <TagFilter tags={tags} selectedTagId={selectedTagId} onSelect={setSelectedTagId} />
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
        <GallerySkeleton />
      ) : groups.length === 0 ? (
        <div className="state-panel">
          <CalendarDays aria-hidden="true" />
          <h3>{photos.length === 0 ? "No progress photos yet" : "No photos under this tag"}</h3>
          <p>
            {photos.length === 0
              ? "Photos added from Pulse on iPhone will appear here."
              : "Choose another tag to keep browsing."}
          </p>
        </div>
      ) : (
        <div className="gallery-sections">
          {groups.map((group) => (
            <section className="date-group" key={group.date}>
              <header>
                <h3>{formatLongDate(group.date)}</h3>
                {weightsByDate.has(group.date) ? (
                  <span>{weightsByDate.get(group.date)?.toFixed(1)} lb</span>
                ) : null}
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
          <div className="load-earlier">
            <button type="button" className="button button--quiet" onClick={onLoadEarlier}>
              Load earlier photos
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
