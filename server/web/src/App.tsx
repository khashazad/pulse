import { useEffect, useState } from "react";

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
import { GalleryView } from "./features/gallery/GalleryView";
import { previewIdentity, previewPhotos, previewTags, previewWeights } from "./devPreview";
import { shiftDateKeyYears, toDateKey } from "./lib/date";
import type { Identity, ProgressPhoto, ProgressPhotoTag, WeightEntry } from "./types";

interface ProgressData {
  photos: ProgressPhoto[];
  tags: ProgressPhotoTag[];
  weights: WeightEntry[];
  from: string;
  to: string;
  loading: boolean;
  loadingEarlier: boolean;
  error?: string;
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
  const [identity, setIdentity] = useState<Identity | null | undefined>(undefined);
  const [authError, setAuthError] = useState<string>();
  const [view, setView] = useState<ProgressView>("gallery");
  const [reloadKey, setReloadKey] = useState(0);
  const [data, setData] = useState<ProgressData>({
    photos: isLocalPreview ? previewPhotos : [],
    tags: isLocalPreview ? previewTags : [],
    weights: isLocalPreview ? previewWeights : [],
    from: shiftDateKeyYears(today, -1),
    to: today,
    loading: false,
    loadingEarlier: false,
  });

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

  useEffect(() => {
    if (isLocalPreview) return;
    const token = getSessionToken();
    if (!identity || !token) return;
    const sessionToken = token;
    const controller = new AbortController();
    setData((current) => ({ ...current, loading: true, error: undefined }));

    /** Load all independent Progress reads concurrently for the active range. */
    async function loadProgress(): Promise<void> {
      try {
        const [tags, photos, weights] = await Promise.all([
          listPhotoTags(sessionToken, controller.signal),
          listPhotos(sessionToken, data.from, data.to, controller.signal),
          listWeights(sessionToken, data.from, data.to, controller.signal),
        ]);
        if (!controller.signal.aborted) {
          setData((current) => ({
            ...current,
            tags,
            photos: mergePhotos([], photos),
            weights: mergeWeights([], weights),
            loading: false,
          }));
        }
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

    void loadProgress();
    return () => controller.abort();
    // `reloadKey` deliberately retries the same range without mutating it.
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
    setData((current) => ({ ...current, photos: [], tags: [], weights: [] }));
  }

  /** Prepend one additional year of photo and weight history. */
  async function loadEarlier(): Promise<void> {
    const token = getSessionToken();
    if (!token || data.loadingEarlier) return;
    const earlierFrom = shiftDateKeyYears(data.from, -1);
    setData((current) => ({ ...current, loadingEarlier: true, error: undefined }));
    try {
      const [photos, weights] = await Promise.all([
        listPhotos(token, earlierFrom, data.from),
        listWeights(token, earlierFrom, data.from),
      ]);
      setData((current) => ({
        ...current,
        from: earlierFrom,
        photos: mergePhotos(current.photos, photos),
        weights: mergeWeights(current.weights, weights),
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
        loadingEarlier: false,
        error: "Could not load earlier photos. Try again in a moment.",
      }));
    }
  }

  if (identity === undefined) return <SessionLoading />;
  if (!identity) return <LoginView error={authError} onLogin={startLogin} />;

  const token = isLocalPreview ? "preview" : getSessionToken();
  if (!token) return <LoginView onLogin={startLogin} />;

  return (
    <AppShell
      identity={identity}
      view={view}
      onViewChange={setView}
      onLogout={() => void signOut()}
    >
      {data.error && data.photos.length > 0 ? (
        <div className="inline-notice" role="status">{data.error}</div>
      ) : null}
      {view === "gallery" ? (
        <GalleryView
          photos={data.photos}
          tags={data.tags}
          weights={data.weights}
          token={token}
          loading={data.loading || data.loadingEarlier}
          error={data.error}
          onRetry={() => setReloadKey((value) => value + 1)}
          onLoadEarlier={() => void loadEarlier()}
        />
      ) : (
        <CompareView
          photos={data.photos}
          tags={data.tags}
          weights={data.weights}
          token={token}
        />
      )}
    </AppShell>
  );
}
