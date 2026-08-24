import { Columns2, Images } from "lucide-react";

export type ProgressView = "timeline" | "compare";

interface BottomNavProps {
  value: ProgressView;
  onChange: (view: ProgressView) => void;
}

/** Render the mobile Browse/Compare tab bar, thumb-reachable at the screen edge. */
export function BottomNav({ value, onChange }: BottomNavProps) {
  return (
    <nav className="bottom-nav" aria-label="Progress view">
      <button
        type="button"
        className={value === "timeline" ? "bottom-nav__item bottom-nav__item--active" : "bottom-nav__item"}
        aria-pressed={value === "timeline"}
        onClick={() => onChange("timeline")}
      >
        <Images aria-hidden="true" size={21} />
        <span>Browse</span>
      </button>
      <button
        type="button"
        className={value === "compare" ? "bottom-nav__item bottom-nav__item--active" : "bottom-nav__item"}
        aria-pressed={value === "compare"}
        onClick={() => onChange("compare")}
      >
        <Columns2 aria-hidden="true" size={21} />
        <span>Compare</span>
      </button>
    </nav>
  );
}
