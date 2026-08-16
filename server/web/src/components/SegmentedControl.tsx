import { Columns2, Images } from "lucide-react";

export type ProgressView = "timeline" | "compare";

interface SegmentedControlProps {
  value: ProgressView;
  onChange: (view: ProgressView) => void;
}

/** Render the Timeline and Compare destinations in a compact switcher. */
export function SegmentedControl({ value, onChange }: SegmentedControlProps) {
  return (
    <div className="segmented segmented--compact" role="group" aria-label="Progress view">
      <button
        type="button"
        className={value === "timeline" ? "segmented__item segmented__item--active" : "segmented__item"}
        aria-pressed={value === "timeline"}
        onClick={() => onChange("timeline")}
      >
        <Images aria-hidden="true" size={16} />
        Timeline
      </button>
      <button
        type="button"
        className={value === "compare" ? "segmented__item segmented__item--active" : "segmented__item"}
        aria-pressed={value === "compare"}
        aria-label="Compare view"
        onClick={() => onChange("compare")}
      >
        <Columns2 aria-hidden="true" size={16} />
        Compare
      </button>
    </div>
  );
}
