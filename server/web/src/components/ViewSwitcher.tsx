import { Columns2, Images } from "lucide-react";

import type { ProgressView } from "./BottomNav";

interface ViewSwitcherProps {
  value: ProgressView;
  onChange: (view: ProgressView) => void;
}

/** Render the desktop Browse/Compare switcher that sits in the top bar. */
export function ViewSwitcher({ value, onChange }: ViewSwitcherProps) {
  return (
    <div className="view-switcher" role="group" aria-label="Progress view">
      <button
        type="button"
        className={value === "timeline" ? "view-switcher__item view-switcher__item--active" : "view-switcher__item"}
        aria-pressed={value === "timeline"}
        onClick={() => onChange("timeline")}
      >
        <Images aria-hidden="true" size={16} />
        Browse
      </button>
      <button
        type="button"
        className={value === "compare" ? "view-switcher__item view-switcher__item--active" : "view-switcher__item"}
        aria-pressed={value === "compare"}
        onClick={() => onChange("compare")}
      >
        <Columns2 aria-hidden="true" size={16} />
        Compare
      </button>
    </div>
  );
}
