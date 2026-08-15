import type { ProgressPhotoTag } from "../types";

interface TagFilterProps {
  tags: ProgressPhotoTag[];
  selectedTagId: string | null;
  onSelect: (tagId: string | null) => void;
}

/** Render a horizontally scrollable, single-select progress-photo tag filter. */
export function TagFilter({ tags, selectedTagId, onSelect }: TagFilterProps) {
  return (
    <div className="tag-filter" role="toolbar" aria-label="Filter progress photos">
      <button
        type="button"
        className={selectedTagId === null ? "tag-chip tag-chip--active" : "tag-chip"}
        aria-pressed={selectedTagId === null}
        aria-label="Show all tags"
        onClick={() => onSelect(null)}
      >
        All
      </button>
      {tags.map((tag) => (
        <button
          key={tag.id}
          type="button"
          className={selectedTagId === tag.id ? "tag-chip tag-chip--active" : "tag-chip"}
          aria-pressed={selectedTagId === tag.id}
          aria-label={`Filter by ${tag.name}`}
          onClick={() => onSelect(tag.id)}
        >
          {tag.name}
        </button>
      ))}
    </div>
  );
}
