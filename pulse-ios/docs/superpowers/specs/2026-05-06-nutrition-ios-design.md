# Nutrition iOS — Design

**Date:** 2026-05-06
**Status:** Approved (brainstorming)
**Sibling repo:** `../nutrition-server` (FastAPI, deployed on Railway)

## Goal

A native iPhone app named **Nutrition** that displays the user's daily and historical food intake from the existing `nutrition-server` API. Read-only viewer (v1). Single user (`user_key` hardcoded to `khash`, matching the server's `DEFAULT_USER_KEY`).

## Scope

In:
- View today's macro totals (Calorie, Protein, Carbs, Fat) and entries.
- View any past day's totals and entries via a date picker.
- View a 7-day rolling weekly summary (bar chart of daily kcal + average macros).
- Configure server URL + API key on first launch via Settings.

Out (v1, may add later):
- Logging / editing / deleting food entries.
- USDA search.
- Setting targets.
- Widgets, Watch app, notifications.
- Local cache or offline mode.
- Multi-user.

## Architecture

Single-target SwiftUI app, minimum iOS 17 (uses `@Observable`, `NavigationStack`, `ContentUnavailableView`).

Three layers:

- **Networking** — `NutritionClient` actor wraps `URLSession`. One method per endpoint. Sends `X-API-Key` from Keychain on every request. Rebuilt when settings change.
- **State** — One `@Observable` view-model per screen (`DayMacroModel`, `WeekModel`). Each owns a `LoadState<T>` enum: `idle / loading / loaded(T) / failed(NutritionError)`. `DayMacroModel` takes a date in its initializer and is reused by both the Today tab and the pushed DayDetail destination.
- **UI** — SwiftUI views. Floating dock is a custom view overlaid on the root container via `.overlay(alignment: .bottom)`.

Server is the source of truth. No persistent local cache. Pull-to-refresh on every data screen is the user's retry mechanism.

## Server endpoints used

All require `X-API-Key` header. All accept `?user_key=khash` (we send it explicitly so we don't depend on server defaults).

| Endpoint | Purpose |
|---|---|
| `GET /summary/{date}` | Today / DayDetail. Returns targets, consumed totals, remaining, and entries for the date. Returns 404 if no target profile exists. |
| `GET /logs?from=&to=` | Week view. Returns daily aggregate totals (kcal/P/C/F + entry count) per day in range, ordered desc. |
| `GET /entries?date=` | Not used in v1 — `/summary/{date}` already returns entries. Reserved for future per-day workflows. |

## Components

```
NutritionApp
└── RootView                           (owns @State tab: Today|Week, sheet/path state)
    ├── NavigationStack(path)
    │   └── (top-level content, switched on tab)
    │       ├── DayMacroView(date: today)     ← shown when tab == Today
    │       │   ├── MacroRing                 (kcal vs target)
    │       │   ├── MacroTotalsRow            (P/C/F totals)
    │       │   └── EntryList → EntryRow      (kcal + P/C/F dots per entry)
    │       └── WeekView                       ← shown when tab == Week
    │           ├── DailyKcalBars              (7 bars, M-S labels)
    │           └── AverageMacrosTable         (avg kcal/P/C/F over the week)
    │   └── (pushed destination)
    │       └── DayMacroView(date: picked)    ← from date picker; same view, different date
    │
    ├── .overlay(alignment: .bottom) → FloatingDock
    │       [Today] [Week] [📅 picker]
    │       (visible on top-level only — hidden when path.count > 0)
    │
    └── .sheet → DatePickerSheet | SettingsView

SettingsView (gear icon top-right; auto-presented & non-dismissable if not configured)
    - Base URL field      → UserDefaults
    - API key field       → Keychain (kSecClassGenericPassword, account "default", service "com.khxsh.nutrition.apikey")
```

`DayMacroView(date:)` is **one view** used twice: as the Today tab's content (with `date = .today`) and as the destination pushed from the date picker (with the picked date). Reuse keeps the day-rendering logic in a single place. The floating dock is bound to `RootView`'s tab state and is hidden whenever a destination is pushed onto the `NavigationStack` (so the dock doesn't compete with the back button on DayDetail).

## Shared types

Mirror server response models from `src/nutrition_server/models/`:

- `DailySummary` ↔ `DailySummaryResponse` (targets, consumed, remaining, entries)
- `DailyLog` ↔ one row from `LogsListResponse.logs[]`
- `FoodEntry` ↔ entry shape (id, name, kcal, protein_g, carbs_g, fat_g, qty, etc.)
- `MacroTargets` (optional, embedded in `DailySummary`)

`JSONDecoder` config:
- `dateDecodingStrategy = .iso8601` for timestamps
- Custom strategy for date-only fields (`YYYY-MM-DD`) on `DailyLog.date` and `EntriesListResponse.date`

## Data flow

**App launch:**
1. `RootView` reads URL from `UserDefaults`, key from Keychain.
2. If either missing → present `SettingsView` modally (cannot dismiss until both set).
3. Otherwise → `TodayView` mounts and fires `client.summary(date: today)` on appear.

**Floating dock interactions** (state lives in `RootView` as `@State var tab: Tab` and `@State var path: NavigationPath`):
- `Today` → set `tab = .today`. If already Today, scroll-to-top + refresh.
- `Week` → set `tab = .week`. `WeekView` fires `client.logs(from: today-6, to: today)` on appear (rolling 7-day window ending today).
- `📅` → present `DatePickerSheet`. On date selection → dismiss sheet, append picked date to `path` (pushes `DayMacroView(date: picked)`).
- Dock visibility: shown when `path.isEmpty`; hidden otherwise.

**Pull-to-refresh** on Today / Week / DayDetail re-runs the same fetch.

**Settings change** → `NutritionClient` is rebuilt with new URL/key; current view re-fetches automatically via task cancellation + restart.

**Date handling:** Today's date is computed once per appear in the device's local timezone. We send a `YYYY-MM-DD` string; the server applies its configured `TZ`.

## Error handling

`NutritionClient` throws `NutritionError`:

```swift
enum NutritionError: Error {
    case notConfigured              // URL or key missing
    case unauthorized               // 401/403 — wrong key
    case notFound                   // 404 — e.g. no targets set yet
    case network(URLError)          // offline, timeout, DNS
    case decoding(DecodingError)    // server response shape changed
    case server(status: Int)        // 5xx
}
```

Each screen has three states:
- **Loading** → `ProgressView()` centered.
- **Error** → `ContentUnavailableView` with short message + "Retry" button. `.unauthorized` adds "Open Settings"; `.notConfigured` opens Settings directly.
- **Empty** (no entries logged yet) → `ContentUnavailableView("No entries logged", systemImage: "fork.knife")`.

**Special case — no targets set:** `/summary/{date}` returns 404 if no target profile exists. Today/DayDetail handle this by showing macro totals only (no rings/remaining), with a small banner: "Set targets in the server to see goals."

No retry logic, no offline cache. Pull-to-refresh is the user's retry.

## Testing

Minimal — this is a personal viewer.

- **Unit tests** for `NutritionClient` decoding only. Capture sample JSON via `curl` against the live server, check into `Tests/Fixtures/` (`summary.json`, `logs.json`). Assert each fixture decodes into the expected model. Catches API drift if the server changes its response shape.
- **SwiftUI Previews** for every view with a stub `NutritionClient` returning fixed data. Iterate visually in Xcode previews. No XCTest UI tests.
- **No app-side integration tests** — the server has its own.

Total: ~5 unit tests.

## Configuration & secrets

- **Base URL** (e.g. `https://nutrition-server.up.railway.app`) → `UserDefaults` key `nutrition.baseURL`.
- **API key** → iOS Keychain, `kSecClassGenericPassword`, service `com.khxsh.nutrition.apikey`, account `default`.
- **`user_key`** → hardcoded constant `"khash"` (matches `nutrition-server/.env` `DEFAULT_USER_KEY`).
- **Bundle ID** → `com.khxsh.nutrition`.
- Free Apple ID signing — re-sign every 7 days via Xcode. Bundle ID is stable.

Nothing secret is committed to source.

## Build & install

- Open `Nutrition.xcodeproj` in Xcode.
- Select your iPhone (must be plugged in or paired wirelessly), ⌘R.
- First time on device: Settings → General → VPN & Device Management → trust your developer cert.
- Re-sign every 7 days.

## Open items / future work

- USDA search and food logging (would mirror the MCP tool surface).
- Setting macro targets from the app.
- Local cache for offline viewing (likely `URLCache` first, before reaching for SwiftData).
- iOS widget showing today's remaining macros.
