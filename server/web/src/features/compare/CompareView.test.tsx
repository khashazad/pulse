import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import type { ProgressPhoto, ProgressPhotoTag, WeightEntry } from "../../types";
import { CompareView } from "./CompareView";

/** Build a tag fixture in the server's stable display order. */
function tag(id: string, name: string, sortOrder: number): ProgressPhotoTag {
  return {
    id,
    name,
    normalized_name: id,
    sort_order: sortOrder,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  };
}

const tags: ProgressPhotoTag[] = [
  tag("front", "Front", 0),
  tag("side", "Side", 1),
  tag("back", "Back", 2),
];

/** Build a comparison photo fixture. */
function photo(id: string, date: string, tagId: string): ProgressPhoto {
  return {
    id,
    date,
    tag_id: tagId,
    mime: "image/jpeg",
    bytes: 100,
    sha256: `sha-${id}`,
    updated_at: `${date}T12:00:00Z`,
  };
}

// Front pairs only across Jun/Aug, Side only across Jul/Aug, Back across all
// three — so each pose is comparable on a different set of dates.
const photos = [
  photo("old-front", "2026-06-01", "front"),
  photo("new-front", "2026-08-01", "front"),
  photo("new-side", "2026-08-01", "side"),
  photo("middle-side", "2026-07-01", "side"),
  photo("old-back", "2026-06-01", "back"),
  photo("middle-back", "2026-07-01", "back"),
  photo("new-back", "2026-08-01", "back"),
];

const weights: WeightEntry[] = [
  {
    id: "weight-old",
    log_date: "2026-07-01",
    weight_lb: 190,
    source_unit: "lb",
    created_at: "2026-07-01T12:00:00Z",
    updated_at: "2026-07-01T12:00:00Z",
  },
  {
    id: "weight-new",
    log_date: "2026-08-01",
    weight_lb: 182.4,
    source_unit: "lb",
    created_at: "2026-08-01T12:00:00Z",
    updated_at: "2026-08-01T12:00:00Z",
  },
];

describe("CompareView", () => {
  beforeEach(() => {
    localStorage.clear();
    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation(
        async () => new Response(new Blob(["jpeg"], { type: "image/jpeg" })),
      ),
    );
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
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  test("defaults to the two newest dates and a pose that has both sides", () => {
    render(<CompareView photos={photos} tags={tags} weights={weights} token="token" />);

    expect(
      screen.getByRole("button", { name: "Choose earlier date, currently Jul 1, 2026" }),
    ).toBeVisible();
    expect(
      screen.getByRole("button", { name: "Choose later date, currently Aug 1, 2026" }),
    ).toBeVisible();
    expect(screen.getByText("-7.6 lb")).toBeVisible();
    expect(screen.getByText("31 days apart")).toBeVisible();
    // Front has no Jul 1 photo, so Side is the first pose that actually pairs.
    expect(screen.getByRole("tab", { name: "Side", selected: true })).toBeVisible();
  });

  test("applies a quick preset and re-picks a pose that pairs at the new dates", () => {
    render(<CompareView photos={photos} tags={tags} weights={weights} token="token" />);

    fireEvent.click(screen.getByRole("button", { name: "First" }));

    expect(
      screen.getByRole("button", { name: "Choose earlier date, currently Jun 1, 2026" }),
    ).toBeVisible();
    // Side no longer pairs at Jun 1, so it falls back to Front.
    expect(screen.getByRole("tab", { name: "Front", selected: true })).toBeVisible();
  });

  test("keeps an explicitly chosen pose across a date change while it still pairs", () => {
    render(<CompareView photos={photos} tags={tags} weights={weights} token="token" />);

    fireEvent.click(screen.getByRole("tab", { name: "Back" }));
    fireEvent.click(screen.getByRole("button", { name: "First" }));

    // Back pairs at Jun 1 too, so the reader's choice survives rather than
    // silently reverting to the first pairing pose (Front).
    expect(screen.getByRole("tab", { name: "Back", selected: true })).toBeVisible();
  });

  test("drops an explicitly chosen pose once it stops pairing", () => {
    render(<CompareView photos={photos} tags={tags} weights={weights} token="token" />);

    fireEvent.click(screen.getByRole("tab", { name: "Side" }));
    fireEvent.click(screen.getByRole("button", { name: "First" }));

    expect(screen.getByRole("tab", { name: "Front", selected: true })).toBeVisible();
  });



  test("opens the calendar date picker from a corner date label", () => {
    render(<CompareView photos={photos} tags={tags} weights={weights} token="token" />);

    fireEvent.click(
      screen.getByRole("button", { name: "Choose earlier date, currently Jul 1, 2026" }),
    );
    expect(screen.getByRole("dialog", { name: "Choose earlier date" })).toBeVisible();
  });

  test("opens the fullscreen viewer from a photo, not from the date control", () => {
    render(<CompareView photos={photos} tags={tags} weights={weights} token="token" />);

    fireEvent.click(
      screen.getByRole("button", { name: "Open Side progress photo from Aug 1, 2026" }),
    );
    expect(screen.getByRole("dialog", { name: "Progress photo viewer" })).toBeVisible();
  });

  test("shows both sides side by side with their own date controls", () => {
    render(<CompareView photos={photos} tags={tags} weights={weights} token="token" />);

    expect(
      screen.getByRole("button", { name: "Choose earlier date, currently Jul 1, 2026" }),
    ).toBeVisible();
    expect(
      screen.getByRole("button", { name: "Choose later date, currently Aug 1, 2026" }),
    ).toBeVisible();
    expect(
      screen.getByRole("button", { name: "Open Side progress photo from Jul 1, 2026" }),
    ).toBeVisible();
    expect(
      screen.getByRole("button", { name: "Open Side progress photo from Aug 1, 2026" }),
    ).toBeVisible();
  });

  test("does not request an image for a pose that is missing on one side", () => {
    render(<CompareView photos={photos} tags={tags} weights={weights} token="token" />);

    fireEvent.click(screen.getByRole("tab", { name: "Front" }));

    // Front has no Jul 1 photo; the absent side must not turn into a request
    // for `/measures/photos/` with an empty id.
    const requested = vi.mocked(fetch).mock.calls.map((call) => String(call[0]));
    expect(requested.some((url) => url.startsWith("/measures/photos/?"))).toBe(false);
    expect(screen.getByText("No Front photo")).toBeVisible();
  });

  test("lets the reader steer away from a seeded comparison", () => {
    render(
      <CompareView
        photos={photos}
        tags={tags}
        weights={weights}
        token="token"
        seedLeftDate="2026-06-01"
        seedRightDate="2026-08-01"
      />,
    );
    expect(
      screen.getByRole("button", { name: "Choose earlier date, currently Jun 1, 2026" }),
    ).toBeVisible();

    fireEvent.click(screen.getByRole("button", { name: "1m" }));

    expect(
      screen.getByRole("button", { name: "Choose earlier date, currently Jul 1, 2026" }),
    ).toBeVisible();
  });

  test("re-applies the seed when a fresh compare request arrives", () => {
    const view = (requestId: number, left: string) => (
      <CompareView
        photos={photos}
        tags={tags}
        weights={weights}
        token="token"
        seedLeftDate={left}
        seedRightDate="2026-08-01"
        seedRequestId={requestId}
      />
    );
    const { rerender } = render(view(1, "2026-06-01"));

    fireEvent.click(screen.getByRole("button", { name: "1m" }));
    expect(
      screen.getByRole("button", { name: "Choose earlier date, currently Jul 1, 2026" }),
    ).toBeVisible();

    // A second "compare this day" click on the same day must still take effect.
    rerender(view(2, "2026-06-01"));
    expect(
      screen.getByRole("button", { name: "Choose earlier date, currently Jun 1, 2026" }),
    ).toBeVisible();
  });
});
