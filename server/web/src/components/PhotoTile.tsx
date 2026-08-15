import { ImageOff } from "lucide-react";

import { useAuthorizedImage } from "../hooks/useAuthorizedImage";
import { parseDateKey } from "../lib/date";
import type { ProgressPhoto } from "../types";

interface PhotoTileProps {
  photo: ProgressPhoto;
  tagName: string;
  weightLb?: number;
  token: string;
  onOpen: (trigger: HTMLButtonElement) => void;
}

/** Render a locale-aware compact date for photo accessible names. */
function tileDate(value: string): string {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
  }).format(parseDateKey(value));
}

/** Render one authorized 4:5 progress-photo tile with local image states. */
export function PhotoTile({
  photo,
  tagName,
  weightLb,
  token,
  onOpen,
}: PhotoTileProps) {
  const image = useAuthorizedImage(token, photo.id, "thumb");
  const date = tileDate(photo.date);
  const accessibleName = `Open ${tagName} progress photo from ${date}`;

  return (
    <button
      className="photo-tile"
      type="button"
      aria-label={accessibleName}
      onClick={(event) => onOpen(event.currentTarget)}
    >
      <span className="photo-tile__media">
        {image.url ? (
          <img src={image.url} alt={`${tagName} progress photo from ${date}`} />
        ) : image.error ? (
          <span className="photo-tile__failure" role="status">
            <ImageOff aria-hidden="true" size={22} />
            Image unavailable
          </span>
        ) : (
          <span className="photo-tile__skeleton" aria-label="Loading photo" />
        )}
      </span>
      <span className="photo-tile__meta">
        <span>{tagName}</span>
        {weightLb !== undefined ? <span>{weightLb.toFixed(1)} lb</span> : null}
      </span>
    </button>
  );
}
