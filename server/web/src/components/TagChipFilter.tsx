import type { ProgressPhotoTag } from "../types";

interface TagChipFilterProps {
  tags: ProgressPhotoTag[];
  selectedTagIds: Set<string> | null;
  onToggle: (tagId: string) => void;
  onSelectAll: () => void;
}

/** Render horizontally scrollable multi-select tag chips with an All reset. */
export function TagChipFilter({
  tags,
  selectedTagIds,
  onToggle,
  onSelectAll,
}: TagChipFilterProps) {
  const allActive = !selectedTagIds || selectedTagIds.size === 0;

  return (
    <div className="tag-filter" role="toolbar" aria-label="Filter progress photos by tag">
      <button
        type="button"
        className={allActive ? "tag-chip tag-chip--active" : "tag-chip"}
        aria-pressed={allActive}
        aria-label="Show all tags"
        onClick={onSelectAll}
      >
        All
      </button>
      {tags.map((tag) => {
        const active = selectedTagIds?.has(tag.id) ?? false;
        return (
          <button
            key={tag.id}
            type="button"
            className={active ? "tag-chip tag-chip--active" : "tag-chip"}
            aria-pressed={active}
            aria-label={`Toggle ${tag.name} tag`}
            onClick={() => onToggle(tag.id)}
          >
            {tag.name}
          </button>
        );
      })}
    </div>
  );
}
