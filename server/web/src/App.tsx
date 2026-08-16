import { useCallback, useEffect, useRef, useState } from "react";

import { HttpError } from "./api/http";
import { listPhotos, listPhotoTags, listWeights } from "./api/pulse";
import { createLoginUrl } from "./auth/pkce";
import {
  clearSession,
  finishGoogleLogin,
  getSessionToken,
  logout,
  restoreSession,
} from "./auth/session";
import { AppShell } from "./components/AppShell";
import { LoginView } from "./components/LoginView";
import type { ProgressView } from "./components/SegmentedControl";
import { CompareView } from "./features/compare/CompareView";
import { CalendarModal } from "./features/calendar/CalendarModal";
import { TimelineView } from "./features/gallery/TimelineView";
import { previewIdentity, previewPhotos, previewRangeFrom, previewRangeTo, previewTags, previewWeights } from "./devPreview";
import { shiftDateKeyYears, toDateKey } from "./lib/date";
import {
  mergeLoadedSpan,
  missingWindows,
  monthBounds,
  type DateWindow,
} from "./lib/range";
import { captureDatesNewestFirst } from "./lib/progress";
import type { Identity, ProgressPhoto, ProgressPhotoTag, WeightEntry } from "./types";

interface ProgressData {
  photos: ProgressPhoto[];
  tags: ProgressPhotoTag[];
  weights: WeightEntry[];
  loading: boolean;
  loadingEarlier: boolean;
  error?: string;
}

interface CompareSeed {
  left?: string;
  right?: string;
}

/** Merge server records by id while preserving newest-first photo ordering. */
function mergePhotos(current: ProgressPhoto[], incoming: ProgressPhoto[]): ProgressPhoto[] {
  return [...new Map([...current, ...incoming].map((photo) => [photo.id, photo])).values()]
    .toSorted((left, right) =>
      right.date.localeCompare(left.date) || right.updated_at.localeCompare(left.updated_at),
    );
}

/** Merge weight rows by date because the server permits one reading per day. */
function mergeWeights(current: WeightEntry[], incoming: WeightEntry[]): WeightEntry[] {
  return [...new Map([...current, ...incoming].map((entry) => [entry.log_date, entry])).values()]
    .toSorted((left, right) => right.log_date.localeCompare(left.log_date));
}

/** Render a restrained full-page state while the stored session is verified. */
function SessionLoading() {
  return (
    <main className="session-loading" aria-label="Loading Pulse">
      <div className="pulse-loader"><span /><span /><span /></div>
      <p>Finding your timeline…</p>
    </main>
  );
}

/** Own browser authentication, read-only Progress data, and top-level view state. */
export function App() {
  const today = toDateKey(new Date());
  const isLocalPreview = import.meta.env.DEV && new URLSearchParams(location.search).get("preview") === "1";
  const initialFrom = shiftDateKeyYears(today, -1);
  const [identity, setIdentity] = useState<Identity | null | undefined>(undefined);
  const [authError, setAuthError] = useState<string>();
  const [view, setView] = useState<ProgressView>("timeline");
  const [reloadKey, setReloadKey] = useState(0);
  const [loadedSpan, setLoadedSpan] = useState<DateWindow | null>(
    isLocalPreview ? { from: previewRangeFrom, to: previewRangeTo } : null,
  );
  const [calendarOpen, setCalendarOpen] = useState(false);
  const [calendarTrigger, setCalendarTrigger] = useState<HTMLElement | null>(null);
  const [highlightDate, setHighlightDate] = useState<string | null>(null);
  const [scrollToDate, setScrollToDate] = useState<string | null>(null);
  const [compareSeed, setCompareSeed] = useState<CompareSeed | null>(null);
  const [data, setData] = useState<ProgressData>({
    photos: isLocalPreview ? previewPhotos : [],
    tags: isLocalPreview ? previewTags : [],
    weights: isLocalPreview ? previewWeights : [],
    loading: false,
    loadingEarlier: false,
  });
  const loadedSpanRef = useRef(loadedSpan);
  loadedSpanRef.current = loadedSpan;

  useEffect(() => {
    let active = true;

    /** Complete a callback or verify the existing session on first mount. */
    async function initializeSession(): Promise<void> {
      if (isLocalPreview) {
        setIdentity(previewIdentity);
        return;
      }
      try {
        const restored =
          location.pathname === "/login/callback"
            ? await finishGoogleLogin(location.search)
            : await restoreSession();
        if (location.pathname === "/login/callback") {
          history.replaceState({}, "", "/");
        }
        if (active) setIdentity(restored);
      } catch (error) {
        clearSession();
        if (location.pathname === "/login/callback") {
          history.replaceState({}, "", "/");
        }
        if (active) {
          setAuthError(error instanceof Error ? error.message : "Sign-in failed.");
          setIdentity(null);
        }
      }
    }

    void initializeSession();
    return () => {
      active = false;
    };
  }, [isLocalPreview]);

  /** Fetch any missing ≤366-day windows and merge them into local state. */
  const ensureRangeLoaded = useCallback(
    async (from: string, to: string, options?: { background?: boolean }): Promise<void> => {
      if (isLocalPreview) return;
      const token = getSessionToken();
      if (!token) return;

      const windows = missingWindows(
        loadedSpanRef.current?.from ?? null,
        loadedSpanRef.current?.to ?? null,
        from,
        to,
      );
      if (windows.length === 0) return;

      setData((current) => ({
        ...current,
        loadingEarlier: true,
        loading: options?.background ? current.loading : true,
        error: undefined,
      }));

      try {
        let span = loadedSpanRef.current;
        let incomingPhotos: ProgressPhoto[] = [];
        let incomingWeights: WeightEntry[] = [];

        for (const window of windows) {
          const [photos, weights] = await Promise.all([
            listPhotos(token, window.from, window.to),
            listWeights(token, window.from, window.to),
          ]);
          incomingPhotos = mergePhotos(incomingPhotos, photos);
          incomingWeights = mergeWeights(incomingWeights, weights);
          span = mergeLoadedSpan(span, window);
        }

        loadedSpanRef.current = span;
        setLoadedSpan(span);
        setData((current) => ({
          ...current,
          photos: mergePhotos(current.photos, incomingPhotos),
          weights: mergeWeights(current.weights, incomingWeights),
          loading: false,
          loadingEarlier: false,
        }));
      } catch (error) {
        if (error instanceof HttpError && error.status === 401) {
          clearSession();
          setIdentity(null);
          return;
        }
        setData((current) => ({
          ...current,
          loading: false,
          loadingEarlier: false,
          error: "Could not load progress photos. Check your connection and try again.",
        }));
      }
    },
    [isLocalPreview],
  );

  useEffect(() => {
    if (isLocalPreview) return;
    const token = getSessionToken();
    if (!identity || !token) return;
    const sessionToken = token;
    const controller = new AbortController();

    /** Load tags and the default one-year window on sign-in. */
    async function loadInitial(): Promise<void> {
      setData((current) => ({ ...current, loading: true, error: undefined }));
      try {
        const tags = await listPhotoTags(sessionToken, controller.signal);
        if (controller.signal.aborted) return;
        setData((current) => ({ ...current, tags }));
        await ensureRangeLoaded(initialFrom, today);
      } catch (error) {
        if (controller.signal.aborted) return;
        if (error instanceof HttpError && error.status === 401) {
          clearSession();
          setIdentity(null);
          return;
        }
        setData((current) => ({
          ...current,
          loading: false,
          error: "Could not load progress photos. Check your connection and try again.",
        }));
      }
    }

    void loadInitial();
    return () => controller.abort();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [identity, isLocalPreview, reloadKey]);

  /** Generate a fresh PKCE pair and navigate into the server-owned Google flow. */
  async function startLogin(): Promise<void> {
    setAuthError(undefined);
    const url = await createLoginUrl();
    location.assign(url);
  }

  /** Revoke the active server session and return to the focused sign-in view. */
  async function signOut(): Promise<void> {
    await logout();
    setIdentity(null);
    setLoadedSpan(null);
    loadedSpanRef.current = null;
    setData((current) => ({ ...current, photos: [], tags: [], weights: [] }));
  }

  /** Prepend one additional year of photo and weight history. */
  async function loadEarlier(): Promise<void> {
    if (data.loadingEarlier) return;
    const span = loadedSpanRef.current;
    if (!span) return;
    const earlierFrom = shiftDateKeyYears(span.from, -1);
    await ensureRangeLoaded(earlierFrom, span.from, { background: true });
  }

  /** Jump into compare with one seed date against the latest capture. */
  function openCompareFromDate(date: string): void {
    const latest = captureDatesNewestFirst(data.photos)[0];
    setCompareSeed({ left: date, right: latest });
    setView("compare");
  }

  /** Open the calendar from the top bar and remember the triggering control. */
  function openCalendar(trigger: HTMLElement | null): void {
    setCalendarTrigger(trigger);
    setCalendarOpen(true);
  }

  /** Navigate the timeline to one capture day selected in the calendar. */
  function focusTimelineDate(date: string): void {
    setView("timeline");
    setHighlightDate(date);
    setScrollToDate(date);
    setCalendarOpen(false);
  }

  if (identity === undefined) return <SessionLoading />;
  if (!identity) return <LoginView error={authError} onLogin={startLogin} />;

  const token = isLocalPreview ? "preview" : getSessionToken();
  if (!token) return <LoginView onLogin={startLogin} />;

  return (
    <>
      <AppShell
        identity={identity}
        view={view}
        onViewChange={(next) => {
          setView(next);
          if (next !== "compare") setCompareSeed(null);
        }}
        onOpenCalendar={() => {
          const trigger = document.querySelector<HTMLElement>('[aria-label="Open photo calendar"]');
          openCalendar(trigger);
        }}
        onLogout={() => void signOut()}
      >
        {data.error && data.photos.length > 0 ? (
          <div className="inline-notice" role="status">{data.error}</div>
        ) : null}
        {view === "timeline" ? (
          <TimelineView
            photos={data.photos}
            tags={data.tags}
            weights={data.weights}
            token={token}
            loading={data.loading || data.loadingEarlier}
            loadingEarlier={data.loadingEarlier}
            error={data.error}
            highlightDate={highlightDate}
            scrollToDate={scrollToDate}
            onScrollToDateHandled={() => setScrollToDate(null)}
            onClearHighlight={() => setHighlightDate(null)}
            onRetry={() => setReloadKey((value) => value + 1)}
            onLoadEarlier={() => void loadEarlier()}
            onCompareFromDate={openCompareFromDate}
          />
        ) : (
          <CompareView
            photos={data.photos}
            tags={data.tags}
            weights={data.weights}
            token={token}
            seedLeftDate={compareSeed?.left}
            seedRightDate={compareSeed?.right}
            onEnsureRange={(from, to) => void ensureRangeLoaded(from, to, { background: true })}
          />
        )}
      </AppShell>

      <CalendarModal
        open={calendarOpen}
        photos={data.photos}
        token={token}
        highlightDate={highlightDate}
        onClose={() => setCalendarOpen(false)}
        restoreFocusTo={calendarTrigger}
        onSelectDate={focusTimelineDate}
        onCompareDate={(date) => {
          openCompareFromDate(date);
          setCalendarOpen(false);
        }}
        onMonthChange={(monthAnchor) => {
          const bounds = monthBounds(monthAnchor);
          void ensureRangeLoaded(bounds.from, bounds.to, { background: true });
        }}
      />
    </>
  );
}
