import { describe, expect, test, vi } from "vitest";

import {
  clearSession,
  finishGoogleLogin,
  getSessionToken,
  logout,
  restoreSession,
  SESSION_TOKEN_KEY,
} from "./session";
import { PKCE_VERIFIER_KEY } from "./pkce";

/** Return a successful JSON response for auth tests. */
function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("browser session", () => {
  test("exchanges the callback code with the stored verifier", async () => {
    sessionStorage.setItem(PKCE_VERIFIER_KEY, "v".repeat(64));
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(
      jsonResponse({
        token: "session-token",
        email: "khash@example.com",
        expires_at: "2026-09-01T00:00:00Z",
      }),
    );

    const identity = await finishGoogleLogin("?code=one-time", fetcher, sessionStorage);

    expect(identity.email).toBe("khash@example.com");
    expect(fetcher).toHaveBeenCalledWith(
      "/auth/google/exchange",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ code: "one-time", code_verifier: "v".repeat(64) }),
      }),
    );
    expect(getSessionToken(sessionStorage)).toBe("session-token");
    expect(sessionStorage.getItem(PKCE_VERIFIER_KEY)).toBeNull();
  });

  test("restores a stored session through whoami", async () => {
    sessionStorage.setItem(SESSION_TOKEN_KEY, "stored-token");
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(
      jsonResponse({ email: "khash@example.com", expires_at: "2026-09-01T00:00:00Z" }),
    );

    const identity = await restoreSession(fetcher, sessionStorage);

    expect(identity?.email).toBe("khash@example.com");
    expect(fetcher).toHaveBeenCalledWith(
      "/auth/whoami",
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: "Bearer stored-token" }),
      }),
    );
  });

  test("clears an unauthorized stored session", async () => {
    sessionStorage.setItem(SESSION_TOKEN_KEY, "expired-token");
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(jsonResponse({}, 401));

    await expect(restoreSession(fetcher, sessionStorage)).resolves.toBeNull();
    expect(getSessionToken(sessionStorage)).toBeNull();
  });

  test("logout clears local state even when the request fails", async () => {
    sessionStorage.setItem(SESSION_TOKEN_KEY, "stored-token");
    const fetcher = vi.fn<typeof fetch>().mockRejectedValue(new Error("offline"));

    await expect(logout(fetcher, sessionStorage)).resolves.toBeUndefined();
    expect(getSessionToken(sessionStorage)).toBeNull();
  });

  test("clearSession removes both auth artifacts", () => {
    sessionStorage.setItem(SESSION_TOKEN_KEY, "stored-token");
    sessionStorage.setItem(PKCE_VERIFIER_KEY, "verifier");
    clearSession(sessionStorage);
    expect(sessionStorage.length).toBe(0);
  });
});
