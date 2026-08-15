/** Session-scoped key holding the verifier across the Google redirect. */
export const PKCE_VERIFIER_KEY = "pulse.pkce_verifier";

/** A browser-generated Proof Key for Code Exchange pair. */
export interface PkcePair {
  verifier: string;
  challenge: string;
}

/** Encode bytes with the unpadded URL-safe Base64 alphabet. */
function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

/** Create a cryptographically random RFC 7636 S256 verifier and challenge. */
export async function createPkcePair(): Promise<PkcePair> {
  const random = crypto.getRandomValues(new Uint8Array(64));
  const verifier = base64Url(random);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(verifier),
  );
  return { verifier, challenge: base64Url(new Uint8Array(digest)) };
}

/** Store a fresh verifier and return the server-owned Google login URL. */
export async function createLoginUrl(
  storage: Storage = sessionStorage,
): Promise<string> {
  const pair = await createPkcePair();
  storage.setItem(PKCE_VERIFIER_KEY, pair.verifier);
  const query = new URLSearchParams({
    client: "web",
    code_challenge: pair.challenge,
    code_challenge_method: "S256",
  });
  return `/auth/google/start?${query.toString()}`;
}
