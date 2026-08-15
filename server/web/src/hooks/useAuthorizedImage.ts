import { useEffect, useState } from "react";

import { loadPhotoBlob } from "../api/pulse";

/** State exposed while one protected image is fetched and materialized. */
export interface AuthorizedImageState {
  url: string | null;
  loading: boolean;
  error: boolean;
}

/** Fetch a protected photo variant and own its temporary browser object URL. */
export function useAuthorizedImage(
  token: string,
  photoId: string,
  size: "thumb" | "full",
): AuthorizedImageState {
  const [state, setState] = useState<AuthorizedImageState>({
    url: null,
    loading: true,
    error: false,
  });

  useEffect(() => {
    if (import.meta.env.DEV && photoId.startsWith("demo-")) {
      setState({ url: `/demo/${photoId}.svg`, loading: false, error: false });
      return;
    }

    const controller = new AbortController();
    let objectUrl: string | null = null;
    setState({ url: null, loading: true, error: false });

    void loadPhotoBlob(token, photoId, size, controller.signal)
      .then((blob) => {
        if (controller.signal.aborted) return;
        objectUrl = URL.createObjectURL(blob);
        setState({ url: objectUrl, loading: false, error: false });
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setState({ url: null, loading: false, error: true });
        }
      });

    return () => {
      controller.abort();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [photoId, size, token]);

  return state;
}
