import { useMemo, useState } from "react";

import { DesktopLayout } from "../../components/DesktopLayout";
import { MonthList } from "../../components/MonthList";
import { MonthScrubber } from "../../components/MonthScrubber";
import { TagChipFilter } from "../../components/TagChipFilter";
import { WeightSnapshotCard } from "../../components/WeightSnapshotCard";
import { useTagSelection } from "../../hooks/useTagSelection";
import { monthBucketsFromPhotos, type MonthBucket } from "../../lib/months";
import type { ProgressPhoto, ProgressPhotoTag, WeightEntry } from "../../types";
import { TimelineView } from "../gallery/TimelineView";

interface BrowseScreenProps {
  photos: ProgressPhoto[];
  tags: ProgressPhotoTag[];
  weights: WeightEntry[];
  token: string;
  loading: boolean;
  loadingEarlier: boolean;
  error?: string;
  highlightDate?: string | null;
  scrollToDate?: string | null;
  onScrollToDateHandled?: () => void;
  onRetry: () => void;
  onLoadEarlier: () => void;
  onCompareFromDate: (date: string) => void;
  onClearHighlight?: () => void;
  onJumpToDate: (date: string) => void;
  isDesktop: boolean;
}

/** Own tag filtering and month navigation, and compose the Browse feed per breakpoint. */
export function BrowseScreen({
  photos,
  tags,
  weights,
  token,
  loading,
  loadingEarlier,
  error,
  highlightDate,
  scrollToDate,
  onScrollToDateHandled,
  onRetry,
  onLoadEarlier,
  onCompareFromDate,
  onClearHighlight,
  onJumpToDate,
  isDesktop,
}: BrowseScreenProps) {
  const { selectedTagIds, selectAll, toggleTag } = useTagSelection(tags.map((tag) => tag.id));
  const months = useMemo(() => monthBucketsFromPhotos(photos), [photos]);
  const [activeMonthKey, setActiveMonthKey] = useState<string | null>(null);

  /** Jump the feed to one month's newest capture date. */
  function handleSelectMonth(bucket: MonthBucket): void {
    setActiveMonthKey(bucket.key);
    onJumpToDate(bucket.anchorDate);
  }

  const timeline = (
    <TimelineView
      photos={photos}
      tags={tags}
      weights={weights}
      token={token}
      selectedTagIds={selectedTagIds}
      loading={loading}
      loadingEarlier={loadingEarlier}
      error={error}
      highlightDate={highlightDate}
      scrollToDate={scrollToDate}
      onScrollToDateHandled={onScrollToDateHandled}
      onRetry={onRetry}
      onLoadEarlier={onLoadEarlier}
      onCompareFromDate={onCompareFromDate}
      onClearHighlight={onClearHighlight}
      onVisibleMonthChange={setActiveMonthKey}
    />
  );

  if (isDesktop) {
    return (
      <DesktopLayout
        sidebar={
          <>
            <WeightSnapshotCard weights={weights} variant="desktop" />
            {tags.length > 0 ? (
              <TagChipFilter
                tags={tags}
                selectedTagIds={selectedTagIds}
                layout="grid"
                onToggle={toggleTag}
                onSelectAll={selectAll}
              />
            ) : null}
            <MonthList months={months} activeKey={activeMonthKey} onSelect={handleSelectMonth} />
          </>
        }
        center={timeline}
      />
    );
  }

  return (
    <div className="browse-screen">
      <WeightSnapshotCard weights={weights} />
      {tags.length > 0 ? (
        <TagChipFilter
          tags={tags}
          selectedTagIds={selectedTagIds}
          onToggle={toggleTag}
          onSelectAll={selectAll}
        />
      ) : null}
      <MonthScrubber months={months} activeKey={activeMonthKey} onSelect={handleSelectMonth} />
      {timeline}
    </div>
  );
}
