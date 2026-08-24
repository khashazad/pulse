import { useMemo } from "react";
import { ChevronDown, ChevronUp } from "lucide-react";

import { daysBetween, toDateKey } from "../lib/date";
import type { WeightEntry } from "../types";

interface WeightSnapshotCardProps {
  weights: WeightEntry[];
  /** Compact mobile card vs. the taller desktop sidebar treatment. */
  variant?: "default" | "desktop";
}

const SPARKLINE_POINTS = 14;
const SPARKLINE_WIDTH = 96;
const SPARKLINE_HEIGHT = 44;

/** Map ascending weight readings onto an SVG polyline, newest point last. */
function sparklinePath(values: number[]): { points: string; last: { x: number; y: number } } | null {
  if (values.length < 2) return null;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;
  const stepX = SPARKLINE_WIDTH / (values.length - 1);
  const coords = values.map((value, index) => {
    const x = index * stepX;
    const y = SPARKLINE_HEIGHT - ((value - min) / span) * SPARKLINE_HEIGHT;
    return { x, y };
  });
  return {
    points: coords.map((point) => `${point.x.toFixed(1)},${point.y.toFixed(1)}`).join(" "),
    last: coords[coords.length - 1],
  };
}

/** Render the latest weight, its delta, and a short trend sparkline. */
export function WeightSnapshotCard({ weights, variant = "default" }: WeightSnapshotCardProps) {
  const ascending = useMemo(
    () => weights.toSorted((left, right) => left.log_date.localeCompare(right.log_date)),
    [weights],
  );
  const latest = ascending[ascending.length - 1];
  const previous = ascending.length > 1 ? ascending[ascending.length - 2] : undefined;
  const delta = latest && previous ? latest.weight_lb - previous.weight_lb : null;
  const daysAgo = latest ? daysBetween(latest.log_date, toDateKey(new Date())) : null;
  const spark = useMemo(
    () => sparklinePath(ascending.slice(-SPARKLINE_POINTS).map((entry) => entry.weight_lb)),
    [ascending],
  );

  if (!latest) return null;

  const down = delta !== null && delta <= 0;

  return (
    <div className={variant === "desktop" ? "weight-card weight-card--desktop" : "weight-card"}>
      <div>
        <div className="weight-card__label">
          {daysAgo === 0 ? "Today" : daysAgo === 1 ? "Yesterday" : `${daysAgo} days ago`}
        </div>
        <div className="weight-card__value">{latest.weight_lb.toFixed(1)} lb</div>
        {delta !== null ? (
          <div className={down ? "weight-card__delta weight-card__delta--down" : "weight-card__delta"}>
            {down ? <ChevronDown aria-hidden="true" size={11} /> : <ChevronUp aria-hidden="true" size={11} />}
            {Math.abs(delta).toFixed(1)} lb
          </div>
        ) : null}
      </div>
      {spark ? (
        <svg
          className="weight-card__spark"
          width={variant === "desktop" ? "100%" : SPARKLINE_WIDTH}
          height={variant === "desktop" ? 90 : SPARKLINE_HEIGHT}
          viewBox={`0 0 ${SPARKLINE_WIDTH} ${SPARKLINE_HEIGHT}`}
          preserveAspectRatio="none"
          fill="none"
        >
          <polyline
            points={spark.points}
            stroke="var(--sapphire)"
            strokeWidth="2.5"
            strokeLinecap="round"
            strokeLinejoin="round"
            fill="none"
          />
          <circle cx={spark.last.x} cy={spark.last.y} r="3.5" fill="var(--sapphire)" />
        </svg>
      ) : null}
    </div>
  );
}
