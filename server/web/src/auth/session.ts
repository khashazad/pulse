import { HttpError, requestJson } from "../api/http";
import type { Identity, SessionResponse } from "../types";
import { PKCE_VERIFIER_KEY } from "./pkce";

/** Session-scoped key holding the opaque Pulse Bearer token. */
export const SESSION_TOKEN_KEY = "pulse.session_token";

/** Authentication-specific failure suitable for the signed-out view. */
export class AuthError extends Error {
  /** Create one user-facing authentication failure. */
  constructor(message: string) {
    super(message);
    this.name = "AuthError";
  }
}

/** Read the current session token without extending its storage lifetime. */
export function getSessionToken(storage: Storage = sessionStorage): string | null {
  return storage.getItem(SESSION_TOKEN_KEY);
}

/** Remove all browser-side authentication artifacts. */
export function clearSession(storage: Storage = sessionStorage): void {
  storage.removeItem(SESSION_TOKEN_KEY);
  storage.removeItem(PKCE_VERIFIER_KEY);
}

/** Exchange the OAuth callback code and retain the returned token for this browser session. */
export async function finishGoogleLogin(
  search: string,
  fetcher: typeof fetch = fetch,
  storage: Storage = sessionStorage,
): Promise<Identity> {
  const query = new URLSearchParams(search);
  const callbackError = query.get("error");
  if (callbackError) {
    storage.removeItem(PKCE_VERIFIER_KEY);
    throw new AuthError(callbackError.replaceAll("_", " "));
  }

  const code = query.get("code");
  const verifier = storage.getItem(PKCE_VERIFIER_KEY);
  if (!code || !verifier) {
    throw new AuthError("Sign-in could not be completed. Please try again.");
  }

  try {
    const response = await fetcher("/auth/google/exchange", {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({ code, code_verifier: verifier }),
    });
    if (!response.ok) throw new AuthError("Sign-in expired. Please try again.");
    const session = (await response.json()) as SessionResponse;
    storage.setItem(SESSION_TOKEN_KEY, session.token);
    return { email: session.email, expires_at: session.expires_at };
  } finally {
    storage.removeItem(PKCE_VERIFIER_KEY);
  }
}

/** Verify a stored Bearer token and return its current identity. */
export async function restoreSession(
  fetcher: typeof fetch = fetch,
  storage: Storage = sessionStorage,
): Promise<Identity | null> {
  const token = getSessionToken(storage);
  if (!token) return null;
  try {
    return await requestJson<Identity>("/auth/whoami", token, {}, fetcher);
  } catch (error) {
    if (error instanceof HttpError && error.status === 401) {
      clearSession(storage);
      return null;
    }
    throw error;
  }
}

/** Revoke the server session when reachable and always clear browser state. */
export async function logout(
  fetcher: typeof fetch = fetch,
  storage: Storage = sessionStorage,
): Promise<void> {
  const token = getSessionToken(storage);
  try {
    if (token) {
      await fetcher("/auth/logout", {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
      });
    }
  } catch {
    // Local logout must remain reliable while offline.
  } finally {
    clearSession(storage);
  }
}
