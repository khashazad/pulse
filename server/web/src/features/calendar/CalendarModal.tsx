import { ChevronLeft, ChevronRight, Columns2 } from "lucide-react";
import { useMemo, useRef, useState } from "react";

import { useModalFocus } from "../../hooks/useModalFocus";
import { buildMonthGrid, parseMonthAnchor, photosDayIndex, shiftMonthAnchor, type DayPhotoSummary } from "../../lib/calendar";
import { formatMonthYear, toDateKey } from "../../lib/date";
import type { ProgressPhoto } from "../../types";
import { CalendarDayThumb } from "./CalendarDayThumb";

const WEEKDAY_LABELS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

interface CalendarGridProps {
  monthAnchor: string;
  dayIndex: Map<string, DayPhotoSummary>;
  token: string;
  highlightDate?: string | null;
  /** When set, only these dates are interactive; otherwise every populated day is. */
  allowedDates?: Set<string> | null;
  onSelectDate: (date: string) => void;
  onCompareDate?: (date: string) => void;
}

/** Render one navigable month grid with optional compare actions per day. */
export function CalendarGrid({
  monthAnchor,
  dayIndex,
  token,
  highlightDate,
  allowedDates,
  onSelectDate,
  onCompareDate,
}: CalendarGridProps) {
  const { year, month } = parseMonthAnchor(monthAnchor);
  const cells = useMemo(() => buildMonthGrid(year, month), [month, year]);
  const today = toDateKey(new Date());
  let renderedThumbs = 0;
  const thumbBudget = 12;

  return (
    <div className="calendar-grid">
      <div className="calendar-grid__weekdays" aria-hidden="true">
        {WEEKDAY_LABELS.map((label) => (
          <span key={label}>{label}</span>
        ))}
      </div>
      <div className="calendar-grid__cells" role="grid" aria-label={formatMonthYear(monthAnchor)}>
        {cells.map((cell, index) => {
          if (!cell.date) {
            return <div className="calendar-day calendar-day--empty" key={`pad-${index}`} role="presentation" />;
          }
          const summary = dayIndex.get(cell.date);
          const populated = Boolean(summary);
          const allowed = populated && (!allowedDates || allowedDates.has(cell.date));
          const classes = [
            "calendar-day",
            populated ? "calendar-day--populated" : "calendar-day--plain",
            allowed ? "calendar-day--clickable" : "",
            cell.date === today ? "calendar-day--today" : "",
            cell.date === highlightDate ? "calendar-day--highlight" : "",
          ]
            .filter(Boolean)
            .join(" ");
          const canThumb = populated && renderedThumbs < thumbBudget;
          if (canThumb) renderedThumbs += 1;

          return (
            <div
              key={cell.date}
              className={classes}
              role="gridcell"
              aria-selected={cell.date === highlightDate}
              aria-label={
                populated
                  ? `${cell.dayOfMonth}, ${summary!.count} photo${summary!.count === 1 ? "" : "s"}`
                  : `${cell.dayOfMonth}, no photos`
              }
            >
              {populated && summary ? (
                <>
                  {canThumb ? (
                    <CalendarDayThumb token={token} photoId={summary.firstPhotoId} enabled={canThumb} />
                  ) : (
                    <span className="calendar-day__dot" aria-hidden="true" />
                  )}
                  {summary.count > 1 ? (
                    <span className="calendar-day__badge">{summary.count}</span>
                  ) : null}
                  <button
                    type="button"
                    className="calendar-day__select"
                    disabled={!allowed}
                    data-autofocus={cell.date === highlightDate ? true : undefined}
                    onClick={() => onSelectDate(cell.date!)}
                  >
                    {cell.dayOfMonth}
                  </button>
                  {onCompareDate && allowed ? (
                    <button
                      type="button"
                      className="calendar-day__compare"
                      aria-label={`Compare from ${cell.date}`}
                      onClick={(event) => {
                        event.stopPropagation();
                        onCompareDate(cell.date!);
                      }}
                    >
                      <Columns2 aria-hidden="true" size={12} />
                    </button>
                  ) : null}
                </>
              ) : (
                <span className="calendar-day__plain">{cell.dayOfMonth}</span>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

interface CalendarModalProps {
  open: boolean;
  photos: ProgressPhoto[];
  token: string;
  initialMonth?: string;
  highlightDate?: string | null;
  onClose: () => void;
  onSelectDate: (date: string) => void;
  onCompareDate?: (date: string) => void;
  onMonthChange?: (monthAnchor: string) => void;
  restoreFocusTo?: HTMLElement | null;
}

/** Render a fullscreen calendar dialog for browsing capture days. */
export function CalendarModal({
  open,
  photos,
  token,
  initialMonth,
  highlightDate,
  onClose,
  onSelectDate,
  onCompareDate,
  onMonthChange,
  restoreFocusTo,
}: CalendarModalProps) {
  const dialogRef = useModalFocus({ open, onClose, restoreFocusTo });
  const todayAnchor = toDateKey(new Date()).slice(0, 8) + "01";
  const [monthAnchor, setMonthAnchor] = useState(initialMonth ?? todayAnchor);
  const dayIndex = useMemo(() => photosDayIndex(photos), [photos]);
  const triggerRef = useRef(restoreFocusTo);

  if (!open) return null;

  /** Jump the visible month and notify the data layer when needed. */
  function setMonth(next: string): void {
    setMonthAnchor(next);
    onMonthChange?.(next);
  }

  return (
    <div
      ref={dialogRef}
      className="calendar-modal"
      role="dialog"
      aria-modal="true"
      aria-label="Photo calendar"
    >
      <div className="calendar-modal__panel">
        <header className="calendar-modal__header">
          <div className="calendar-modal__nav">
            <button
              type="button"
              aria-label="Previous month"
              onClick={() => setMonth(shiftMonthAnchor(monthAnchor, -1))}
            >
              <ChevronLeft aria-hidden="true" />
            </button>
            <h2>{formatMonthYear(monthAnchor)}</h2>
            <button
              type="button"
              aria-label="Next month"
              onClick={() => setMonth(shiftMonthAnchor(monthAnchor, 1))}
            >
              <ChevronRight aria-hidden="true" />
            </button>
          </div>
          <div className="calendar-modal__actions">
            <button
              type="button"
              className="button button--quiet"
              onClick={() => {
                const todayMonth = todayAnchor;
                setMonth(todayMonth);
                onMonthChange?.(todayMonth);
              }}
            >
              Today
            </button>
            <button type="button" className="button button--quiet" aria-label="Close calendar" onClick={onClose}>
              Close
            </button>
          </div>
        </header>
        <CalendarGrid
          monthAnchor={monthAnchor}
          dayIndex={dayIndex}
          token={token}
          highlightDate={highlightDate}
          onSelectDate={(date) => {
            onSelectDate(date);
            onClose();
            triggerRef.current = restoreFocusTo ?? null;
          }}
          onCompareDate={onCompareDate}
        />
      </div>
    </div>
  );
}

interface DatePickerDialogProps {
  open: boolean;
  photos: ProgressPhoto[];
  token: string;
  selectedDate?: string;
  title: string;
  onClose: () => void;
  onSelectDate: (date: string) => void;
  onMonthChange?: (monthAnchor: string) => void;
  restoreFocusTo?: HTMLElement | null;
}

/** Render a calendar dialog limited to days that already have photos. */
export function DatePickerDialog({
  open,
  photos,
  token,
  selectedDate,
  title,
  onClose,
  onSelectDate,
  onMonthChange,
  restoreFocusTo,
}: DatePickerDialogProps) {
  const allowedDates = useMemo(() => new Set(photos.map((photo) => photo.date)), [photos]);
  const initialMonth = selectedDate ? `${selectedDate.slice(0, 8)}01` : toDateKey(new Date()).slice(0, 8) + "01";
  const dialogRef = useModalFocus({ open, onClose, restoreFocusTo });

  if (!open) return null;

  return (
    <div
      ref={dialogRef}
      className="calendar-modal calendar-modal--picker"
      role="dialog"
      aria-modal="true"
      aria-label={title}
    >
      <div className="calendar-modal__panel">
        <header className="calendar-modal__header">
          <h2>{title}</h2>
          <button type="button" className="button button--quiet" aria-label="Close date picker" onClick={onClose}>
            Close
          </button>
        </header>
        <CalendarModalPickerBody
          photos={photos}
          token={token}
          selectedDate={selectedDate}
          initialMonth={initialMonth}
          allowedDates={allowedDates}
          onSelectDate={onSelectDate}
          onClose={onClose}
          onMonthChange={onMonthChange}
        />
      </div>
    </div>
  );
}

interface CalendarModalPickerBodyProps {
  photos: ProgressPhoto[];
  token: string;
  selectedDate?: string;
  initialMonth: string;
  allowedDates: Set<string>;
  onSelectDate: (date: string) => void;
  onClose: () => void;
  onMonthChange?: (monthAnchor: string) => void;
}

/** Own month navigation state for the restricted compare date picker. */
function CalendarModalPickerBody({
  photos,
  token,
  selectedDate,
  initialMonth,
  allowedDates,
  onSelectDate,
  onClose,
  onMonthChange,
}: CalendarModalPickerBodyProps) {
  const [monthAnchor, setMonthAnchor] = useState(initialMonth);
  const dayIndex = useMemo(() => photosDayIndex(photos), [photos]);

  /** Jump the visible month and notify the data layer when needed. */
  function setMonth(next: string): void {
    setMonthAnchor(next);
    onMonthChange?.(next);
  }

  return (
    <>
      <div className="calendar-modal__nav calendar-modal__nav--compact">
        <button type="button" aria-label="Previous month" onClick={() => setMonth(shiftMonthAnchor(monthAnchor, -1))}>
          <ChevronLeft aria-hidden="true" />
        </button>
        <span>{formatMonthYear(monthAnchor)}</span>
        <button type="button" aria-label="Next month" onClick={() => setMonth(shiftMonthAnchor(monthAnchor, 1))}>
          <ChevronRight aria-hidden="true" />
        </button>
      </div>
      <CalendarGrid
        monthAnchor={monthAnchor}
        dayIndex={dayIndex}
        token={token}
        highlightDate={selectedDate}
        allowedDates={allowedDates}
        onSelectDate={(date) => {
          onSelectDate(date);
          onClose();
        }}
      />
    </>
  );
}
