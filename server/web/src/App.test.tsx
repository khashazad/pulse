import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import { PKCE_VERIFIER_KEY } from "./auth/pkce";
import { SESSION_TOKEN_KEY } from "./auth/session";
import { App } from "./App";

/** Build a new one-shot JSON response for the mocked Pulse API. */
function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Route test fetches to deterministic identity, metadata, weight, and image fixtures. */
function authenticatedFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const path = String(input);
  if (path === "/auth/whoami") {
    return Promise.resolve(
      jsonResponse({ email: "khash@example.com", expires_at: "2026-09-01T00:00:00Z" }),
    );
  }
  if (path === "/measures/photo-tags") {
    return Promise.resolve(
      jsonResponse([
        {
          id: "front",
          name: "Front",
          normalized_name: "front",
          sort_order: 0,
          created_at: "2026-01-01T00:00:00Z",
          updated_at: "2026-01-01T00:00:00Z",
        },
      ]),
    );
  }
  if (path.startsWith("/measures/photos?") && !path.includes("size=")) {
    return Promise.resolve(
      jsonResponse([
        {
          id: "photo",
          date: "2026-08-01",
          tag_id: "front",
          mime: "image/jpeg",
          bytes: 100,
          sha256: "sha",
          updated_at: "2026-08-01T12:00:00Z",
        },
      ]),
    );
  }
  if (path.startsWith("/weight?")) return Promise.resolve(jsonResponse([]));
  if (path.startsWith("/measures/photos/photo?")) {
    return Promise.resolve(new Response(new Blob(["jpeg"], { type: "image/jpeg" })));
  }
  if (path === "/auth/logout" && init?.method === "POST") {
    return Promise.resolve(new Response(null, { status: 204 }));
  }
  return Promise.reject(new Error(`Unexpected request: ${path}`));
}

describe("App", () => {
  beforeEach(() => {
    history.replaceState({}, "", "/");
    vi.stubGlobal("fetch", vi.fn(authenticatedFetch));
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: vi.fn(() => "blob:photo"),
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      configurable: true,
      value: vi.fn(),
    });
  });

  afterEach(() => {
    history.replaceState({}, "", "/");
    vi.unstubAllGlobals();
  });

  test("renders the focused Google sign-in view without a stored session", async () => {
    render(<App />);

    expect(await screen.findByRole("button", { name: "Continue with Google" })).toBeVisible();
    expect(screen.getByText("Your progress, in perspective.")).toBeVisible();
  });

  test("renders deterministic local preview data without an authenticated session", async () => {
    history.replaceState({}, "", "/?preview=1");
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Your progression" })).toBeVisible();
    expect(screen.getByText("6 photos")).toBeVisible();
    expect(screen.getByText("preview@pulse.local")).toBeVisible();
    expect(fetch).not.toHaveBeenCalled();
  });

  test("restores a session, loads progress, and switches to compare", async () => {
    sessionStorage.setItem(SESSION_TOKEN_KEY, "stored-token");
    render(<App />);

    expect(await screen.findByText("khash@example.com")).toBeVisible();
    expect(await screen.findByRole("heading", { name: "Your progression" })).toBeVisible();
    expect(
      await screen.findByRole("button", {
        name: "Open Front progress photo from Aug 1, 2026",
      }),
    ).toBeVisible();

    fireEvent.click(screen.getByRole("button", { name: "Compare" }));
    expect(screen.getByRole("heading", { name: "Compare your progress" })).toBeVisible();
  });

  test("completes a Google callback before loading protected data", async () => {
    history.replaceState({}, "", "/login/callback?code=one-time");
    sessionStorage.setItem(PKCE_VERIFIER_KEY, "v".repeat(64));
    vi.mocked(fetch).mockImplementation((input, init) => {
      if (String(input) === "/auth/google/exchange") {
        return Promise.resolve(
          jsonResponse({
            token: "fresh-token",
            email: "khash@example.com",
            expires_at: "2026-09-01T00:00:00Z",
          }),
        );
      }
      return authenticatedFetch(input, init);
    });

    render(<App />);

    expect(await screen.findByRole("heading", { name: "Your progression" })).toBeVisible();
    expect(sessionStorage.getItem(SESSION_TOKEN_KEY)).toBe("fresh-token");
    expect(location.pathname).toBe("/");
  });

  test("signs out on the server and returns to login", async () => {
    sessionStorage.setItem(SESSION_TOKEN_KEY, "stored-token");
    render(<App />);
    await screen.findByText("khash@example.com");

    fireEvent.click(screen.getByRole("button", { name: "Sign out" }));

    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Continue with Google" })).toBeVisible(),
    );
    expect(sessionStorage.getItem(SESSION_TOKEN_KEY)).toBeNull();
  });
});
