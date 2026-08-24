import { Expand, GripVertical, ImageOff } from "lucide-react";
import { useCallback, useRef, useState } from "react";

import { useAuthorizedImage } from "../../hooks/useAuthorizedImage";
import type { ProgressPhoto } from "../../types";

interface CompareSliderProps {
  leftPhoto?: ProgressPhoto;
  rightPhoto?: ProgressPhoto;
  leftLabel: string;
  rightLabel: string;
  tagName: string;
  token: string;
  onExpand?: () => void;
  onEditLeft?: () => void;
  onEditRight?: () => void;
}

/** Render one authorized photo layer, or a muted placeholder, inside the slider. */
function SliderLayer({ photo, token, alt }: { photo?: ProgressPhoto; token: string; alt: string }) {
  const image = useAuthorizedImage(token, photo?.id ?? "", "full");

  if (!photo || image.error) {
    return (
      <div className="compare-slider__empty">
        <ImageOff aria-hidden="true" size={22} />
        <span>{photo ? "Image unavailable" : "No photo"}</span>
      </div>
    );
  }
  return image.url ? <img src={image.url} alt={alt} /> : <div className="compare-slider__skeleton" />;
}

/**
 * Render a draggable onion-skin slider between two photos of the same pose.
 *
 * The frame surface owns exactly one gesture — moving the split — so a tap and
 * a drag do the same predictable thing. Opening fullscreen and re-picking dates
 * are separate controls layered on top.
 */
export function CompareSlider({
  leftPhoto,
  rightPhoto,
  leftLabel,
  rightLabel,
  tagName,
  token,
  onExpand,
  onEditLeft,
  onEditRight,
}: CompareSliderProps) {
  const [pos, setPos] = useState(50);
  const frameRef = useRef<HTMLDivElement>(null);
  const draggingRef = useRef(false);

  const updateFromClientX = useCallback((clientX: number) => {
    const frame = frameRef.current;
    if (!frame) return;
    const rect = frame.getBoundingClientRect();
    if (rect.width === 0) return;
    const raw = ((clientX - rect.left) / rect.width) * 100;
    setPos(Math.max(4, Math.min(96, raw)));
  }, []);

  return (
    <div
      ref={frameRef}
      className="compare-slider"
      role="slider"
      aria-label={`Drag to compare ${tagName} photos`}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(pos)}
      aria-valuetext={`${Math.round(pos)}% ${leftLabel}, ${100 - Math.round(pos)}% ${rightLabel}`}
      tabIndex={0}
      onPointerDown={(event) => {
        event.currentTarget.setPointerCapture?.(event.pointerId);
        draggingRef.current = true;
        updateFromClientX(event.clientX);
      }}
      onPointerMove={(event) => {
        if (draggingRef.current) updateFromClientX(event.clientX);
      }}
      onPointerUp={() => {
        draggingRef.current = false;
      }}
      onPointerCancel={() => {
        draggingRef.current = false;
      }}
      onKeyDown={(event) => {
        if (event.key === "ArrowLeft") {
          event.preventDefault();
          setPos((value) => Math.max(4, value - 5));
        }
        if (event.key === "ArrowRight") {
          event.preventDefault();
          setPos((value) => Math.min(96, value + 5));
        }
      }}
    >
      <div className="compare-slider__layer">
        <SliderLayer photo={rightPhoto} token={token} alt={`${tagName} photo from ${rightLabel}`} />
      </div>
      <div className="compare-slider__layer" style={{ clipPath: `inset(0 ${100 - pos}% 0 0)` }}>
        <SliderLayer photo={leftPhoto} token={token} alt={`${tagName} photo from ${leftLabel}`} />
      </div>

      <button
        type="button"
        className="compare-slider__corner compare-slider__corner--left"
        aria-label={`Choose earlier date, currently ${leftLabel}`}
        onPointerDown={(event) => event.stopPropagation()}
        onClick={onEditLeft}
      >
        <span className="compare-slider__corner-tag">Earlier</span>
        <span>{leftLabel}</span>
      </button>
      <button
        type="button"
        className="compare-slider__corner compare-slider__corner--right"
        aria-label={`Choose later date, currently ${rightLabel}`}
        onPointerDown={(event) => event.stopPropagation()}
        onClick={onEditRight}
      >
        <span className="compare-slider__corner-tag">Later</span>
        <span>{rightLabel}</span>
      </button>

      <div className="compare-slider__divider" style={{ left: `${pos}%` }} />
      <div className="compare-slider__grip" style={{ left: `${pos}%` }}>
        <GripVertical aria-hidden="true" size={18} />
      </div>

      {onExpand ? (
        <button
          type="button"
          className="compare-slider__expand"
          aria-label={`View ${tagName} photos full size`}
          onPointerDown={(event) => event.stopPropagation()}
          onClick={onExpand}
        >
          <Expand aria-hidden="true" size={17} />
        </button>
      ) : null}
    </div>
  );
}
