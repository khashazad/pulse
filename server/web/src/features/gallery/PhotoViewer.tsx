import { ChevronLeft, ChevronRight, X } from "lucide-react";
import { useEffect, useMemo, useRef } from "react";

import { useAuthorizedImage } from "../../hooks/useAuthorizedImage";
import { formatShortDate } from "../../lib/date";
import type { ProgressPhoto, ProgressPhotoTag } from "../../types";

interface PhotoViewerProps {
  photos: ProgressPhoto[];
  selectedId: string;
  tags: ProgressPhotoTag[];
  token: string;
  onSelect: (photoId: string) => void;
  onClose: () => void;
  restoreFocusTo?: HTMLElement | null;
}

/** Render a keyboard-navigable fullscreen viewer for the active photo sequence. */
export function PhotoViewer({
  photos,
  selectedId,
  tags,
  token,
  onSelect,
  onClose,
  restoreFocusTo,
}: PhotoViewerProps) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);
  const selectedIndex = photos.findIndex((photo) => photo.id === selectedId);
  const photo = photos[Math.max(0, selectedIndex)];
  const image = useAuthorizedImage(token, photo.id, "full");
  const tagName = useMemo(
    () => tags.find((tag) => tag.id === photo.tag_id)?.name ?? "Progress",
    [photo.tag_id, tags],
  );

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    closeRef.current?.focus();

    return () => {
      document.body.style.overflow = previousOverflow;
      restoreFocusTo?.focus();
    };
  }, [restoreFocusTo]);

  useEffect(() => {
    /** Handle modal navigation and keep keyboard focus inside the dialog. */
    function handleKeyDown(event: KeyboardEvent): void {
      if (event.key === "Escape") {
        event.preventDefault();
        onClose();
      } else if (event.key === "ArrowLeft" && selectedIndex > 0) {
        event.preventDefault();
        onSelect(photos[selectedIndex - 1].id);
      } else if (event.key === "ArrowRight" && selectedIndex < photos.length - 1) {
        event.preventDefault();
        onSelect(photos[selectedIndex + 1].id);
      } else if (event.key === "Tab") {
        const controls = dialogRef.current?.querySelectorAll<HTMLElement>(
          'button:not([disabled]), [href], [tabindex]:not([tabindex="-1"])',
        );
        if (!controls?.length) return;
        const first = controls[0];
        const last = controls[controls.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose, onSelect, photos, selectedIndex]);

  return (
    <div
      ref={dialogRef}
      className="viewer"
      role="dialog"
      aria-modal="true"
      aria-label="Progress photo viewer"
    >
      <div className="viewer__topbar">
        <div>
          <strong>{tagName}</strong>
          <span>{formatShortDate(photo.date)}</span>
        </div>
        <button ref={closeRef} type="button" aria-label="Close viewer" onClick={onClose}>
          <X aria-hidden="true" />
        </button>
      </div>

      <div className="viewer__stage">
        {image.url ? (
          <img src={image.url} alt={`${tagName} progress photo from ${formatShortDate(photo.date)}`} />
        ) : image.error ? (
          <p role="status">Full-size image unavailable.</p>
        ) : (
          <div className="viewer__loader" aria-label="Loading full-size photo" />
        )}
      </div>

      <button
        className="viewer__nav viewer__nav--previous"
        type="button"
        aria-label="Previous photo"
        disabled={selectedIndex <= 0}
        onClick={() => onSelect(photos[selectedIndex - 1].id)}
      >
        <ChevronLeft aria-hidden="true" />
      </button>
      <button
        className="viewer__nav viewer__nav--next"
        type="button"
        aria-label="Next photo"
        disabled={selectedIndex >= photos.length - 1}
        onClick={() => onSelect(photos[selectedIndex + 1].id)}
      >
        <ChevronRight aria-hidden="true" />
      </button>
      <span className="viewer__count">
        {selectedIndex + 1} / {photos.length}
      </span>
    </div>
  );
}
