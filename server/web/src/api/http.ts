/** Normalized failure returned by the Pulse JSON and blob endpoints. */
export class HttpError extends Error {
  readonly status: number;

  /** Create one HTTP failure with its response status. */
  constructor(status: number, message: string) {
    super(message);
    this.name = "HttpError";
    this.status = status;
  }
}

/** Extract the server detail payload without assuming every failure is JSON. */
async function responseMessage(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as { detail?: string };
    return body.detail || `Request failed (${response.status})`;
  } catch {
    return `Request failed (${response.status})`;
  }
}

/** Send an authenticated request and decode its JSON response. */
export async function requestJson<T>(
  path: string,
  token: string,
  init: RequestInit = {},
  fetcher: typeof fetch = fetch,
): Promise<T> {
  const headers: Record<string, string> = {
    Accept: "application/json",
    Authorization: `Bearer ${token}`,
  };
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  const response = await fetcher(path, { ...init, headers: { ...headers } });
  if (!response.ok) {
    throw new HttpError(response.status, await responseMessage(response));
  }
  return (await response.json()) as T;
}

/** Send an authenticated request and return its binary response body. */
export async function requestBlob(
  path: string,
  token: string,
  signal?: AbortSignal,
  fetcher: typeof fetch = fetch,
): Promise<Blob> {
  const response = await fetcher(path, {
    headers: { Authorization: `Bearer ${token}` },
    signal,
  });
  if (!response.ok) {
    throw new HttpError(response.status, await responseMessage(response));
  }
  return response.blob();
}
