import { useEffect, useRef } from "react";

import type { MonthBucket } from "../lib/months";

interface MonthScrubberProps {
  months: MonthBucket[];
  activeKey: string | null;
  onSelect: (bucket: MonthBucket) => void;
}

/** Render a horizontally scrollable strip of month chips for fast temporal jumps. */
export function MonthScrubber({ months, activeKey, onSelect }: MonthScrubberProps) {
  const stripRef = useRef<HTMLDivElement>(null);
  const activeRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    const strip = stripRef.current;
    const chip = activeRef.current;
    if (!strip || !chip) return;
    // Scroll the strip itself rather than calling scrollIntoView: the active
    // month follows the reader's position in the feed, and scrollIntoView would
    // drag the whole PAGE back to the strip on every change — fighting the very
    // scroll that moved it.
    const centered = chip.offsetLeft - (strip.clientWidth - chip.clientWidth) / 2;
    strip.scrollTo({ left: Math.max(0, centered), behavior: "smooth" });
  }, [activeKey]);

  if (months.length === 0) return null;

  return (
    <div className="month-scrubber" ref={stripRef} role="toolbar" aria-label="Jump to month">
      {months.map((bucket) => {
        const active = bucket.key === activeKey;
        return (
          <button
            key={bucket.key}
            ref={active ? activeRef : undefined}
            type="button"
            className={active ? "month-chip month-chip--active" : "month-chip"}
            aria-pressed={active}
            onClick={() => onSelect(bucket)}
          >
            {bucket.label}
          </button>
        );
      })}
    </div>
  );
}
