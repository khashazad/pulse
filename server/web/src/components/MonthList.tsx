import type { MonthBucket } from "../lib/months";

interface MonthListProps {
  months: MonthBucket[];
  activeKey: string | null;
  onSelect: (bucket: MonthBucket) => void;
}

/** Render a vertical, newest-first month list for the desktop history sidebar. */
export function MonthList({ months, activeKey, onSelect }: MonthListProps) {
  if (months.length === 0) return null;
  const newestFirst = months.toReversed();

  return (
    <div className="month-list" role="toolbar" aria-label="Jump to month" aria-orientation="vertical">
      {newestFirst.map((bucket) => {
        const active = bucket.key === activeKey;
        return (
          <button
            key={bucket.key}
            type="button"
            className={active ? "month-list__item month-list__item--active" : "month-list__item"}
            aria-pressed={active}
            onClick={() => onSelect(bucket)}
          >
            <span>{bucket.label}</span>
            <span className="month-list__dot" aria-hidden="true" />
          </button>
        );
      })}
    </div>
  );
}
