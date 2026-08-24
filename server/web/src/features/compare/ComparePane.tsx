import { CalendarDays, ImageOff } from "lucide-react";

import { useAuthorizedImage } from "../../hooks/useAuthorizedImage";
import type { ProgressPhoto } from "../../types";

interface ComparePaneProps {
  /** Which end of the comparison this pane holds. */
  label: string;
  /** Already-formatted capture date shown on the picker control. */
  dateLabel: string;
  photo?: ProgressPhoto;
  weightLb?: number;
  tagName: string;
  token: string;
  onPickDate: () => void;
  onOpenPhoto: (trigger: HTMLElement) => void;
}

/**
 * Render one side of a comparison: a date picker control above the photo.
 *
 * The date control and the photo are separate buttons, so choosing a date and
 * opening the photo can never be the same click.
 */
export function ComparePane({
  label,
  dateLabel,
  photo,
  weightLb,
  tagName,
  token,
  onPickDate,
  onOpenPhoto,
}: ComparePaneProps) {
  const image = useAuthorizedImage(token, photo?.id ?? "", "full");
  const missing = !photo || image.error;

  return (
    <div className="compare-pane">
      <button
        type="button"
        className="compare-pane__date"
        aria-label={`Choose ${label.toLowerCase()} date, currently ${dateLabel}`}
        onClick={onPickDate}
      >
        <span className="compare-pane__label">{label}</span>
        <span className="compare-pane__value">
          {dateLabel}
          <CalendarDays aria-hidden="true" size={14} />
        </span>
        {weightLb !== undefined ? (
          <span className="compare-pane__weight">{weightLb.toFixed(1)} lb</span>
        ) : null}
      </button>

      {missing ? (
        <div className="compare-pane__media compare-pane__media--empty" role="status">
          <ImageOff aria-hidden="true" size={22} />
          <span>{photo ? "Image unavailable" : `No ${tagName} photo`}</span>
        </div>
      ) : (
        <button
          type="button"
          className="compare-pane__media"
          aria-label={`Open ${tagName} progress photo from ${dateLabel}`}
          onClick={(event) => onOpenPhoto(event.currentTarget)}
        >
          {image.url ? (
            <img src={image.url} alt={`${tagName} progress photo from ${dateLabel}`} />
          ) : (
            <span className="compare-pane__skeleton" aria-label="Loading photo" />
          )}
        </button>
      )}
    </div>
  );
}
