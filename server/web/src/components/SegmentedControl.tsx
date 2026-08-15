import { Columns2, Images } from "lucide-react";

export type ProgressView = "gallery" | "compare";

interface SegmentedControlProps {
  value: ProgressView;
  onChange: (view: ProgressView) => void;
}

/** Render the two top-level read-only Progress destinations. */
export function SegmentedControl({ value, onChange }: SegmentedControlProps) {
  return (
    <div className="segmented" role="group" aria-label="Progress view">
      <button
        type="button"
        className={value === "gallery" ? "segmented__item segmented__item--active" : "segmented__item"}
        aria-pressed={value === "gallery"}
        onClick={() => onChange("gallery")}
      >
        <Images aria-hidden="true" size={17} />
        Gallery
      </button>
      <button
        type="button"
        className={value === "compare" ? "segmented__item segmented__item--active" : "segmented__item"}
        aria-pressed={value === "compare"}
        onClick={() => onChange("compare")}
      >
        <Columns2 aria-hidden="true" size={17} />
        Compare
      </button>
    </div>
  );
}
