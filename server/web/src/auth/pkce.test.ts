import { describe, expect, test } from "vitest";

import { createLoginUrl, createPkcePair, PKCE_VERIFIER_KEY } from "./pkce";

describe("browser PKCE", () => {
  test("creates an RFC 7636 verifier and matching SHA-256 challenge", async () => {
    const pair = await createPkcePair();
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(pair.verifier),
    );
    const expected = btoa(String.fromCharCode(...new Uint8Array(digest)))
      .replaceAll("+", "-")
      .replaceAll("/", "_")
      .replaceAll("=", "");

    expect(pair.verifier.length).toBeGreaterThanOrEqual(43);
    expect(pair.verifier.length).toBeLessThanOrEqual(128);
    expect(pair.challenge).toBe(expected);
  });

  test("stores the verifier and targets the fixed web OAuth client", async () => {
    const url = await createLoginUrl(sessionStorage);
    const parsed = new URL(url, "https://pulse.example.com");

    expect(parsed.pathname).toBe("/auth/google/start");
    expect(parsed.searchParams.get("client")).toBe("web");
    expect(parsed.searchParams.get("code_challenge_method")).toBe("S256");
    expect(parsed.searchParams.get("code_challenge")).toBeTruthy();
    expect(sessionStorage.getItem(PKCE_VERIFIER_KEY)).toBeTruthy();
  });
});
