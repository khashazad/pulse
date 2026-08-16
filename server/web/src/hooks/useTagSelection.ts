import { useCallback, useEffect, useState } from "react";

import {
  parseStoredTagIds,
  serializeTagIds,
  TAG_SELECTION_STORAGE_KEY,
  toggleTagSelection,
} from "../lib/tags";

/** Persist and expose a multi-select progress-photo tag filter. */
export function useTagSelection(validTagIds: string[]) {
  const [selectedTagIds, setSelectedTagIds] = useState<Set<string> | null>(() => {
    try {
      return parseStoredTagIds(localStorage.getItem(TAG_SELECTION_STORAGE_KEY));
    } catch {
      return null;
    }
  });

  useEffect(() => {
    const valid = new Set(validTagIds);
    setSelectedTagIds((current) => {
      if (!current) return null;
      const pruned = new Set([...current].filter((id) => valid.has(id)));
      return pruned.size > 0 ? pruned : null;
    });
  }, [validTagIds]);

  useEffect(() => {
    try {
      localStorage.setItem(TAG_SELECTION_STORAGE_KEY, serializeTagIds(selectedTagIds));
    } catch {
      // Ignore storage failures in private mode or test environments.
    }
  }, [selectedTagIds]);

  /** Reset the filter to show every tag. */
  const selectAll = useCallback((): void => {
    setSelectedTagIds(null);
  }, []);

  /** Toggle one tag id within the active multi-select set. */
  const toggleTag = useCallback((tagId: string): void => {
    setSelectedTagIds((current) => toggleTagSelection(current, tagId));
  }, []);

  /** Return whether one tag chip should render as pressed. */
  const isTagSelected = useCallback(
    (tagId: string): boolean => selectedTagIds?.has(tagId) ?? false,
    [selectedTagIds],
  );

  return { selectedTagIds, selectAll, toggleTag, isTagSelected };
}
