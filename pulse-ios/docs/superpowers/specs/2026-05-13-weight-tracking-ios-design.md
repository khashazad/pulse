# Weight Tracking — iOS

**Status:** Design
**Date:** 2026-05-13
**Companion spec:** `diet-tracker-server/docs/superpowers/specs/2026-05-13-weight-tracking-server-design.md`

## Goal

New "Weight" tab that lets the user log daily weight (kg or lb input, lb storage), view past entries, and see two charts plus an analytics card. Analytics output: maintenance kcal (from a windowed rate-vs-kcal regression), current trend (lb/week), and ETA to a stored target weight. The existing "Log" tab is renamed to "Intake" to keep the Weight tab's inner segmented control labels (`Log` / `Trends`) unambiguous.

## Scope

**In:**
- 4th tab "Weight" in `FloatingDock` and `RootView`.
- Rename existing "Log" tab to "Intake" (label + tab title only).
- New views: `WeightTabRootView`, `WeightLogView`, `WeightTrendsView`, weigh-in editor sheet.
- New models: `WeightEntry`, `WeightUnit`, plus a `target_weight_lb` field on the existing macro-targets model.
- New view models: `WeightLogModel`, `WeightTrendsModel`.
- Pure analytics module `WeightAnalytics` with OLS regression, fully unit-testable.
- Networking additions for the new endpoints; `kg`/`lb` toggle in Settings stored in `@AppStorage`.
- SwiftUI `Charts` framework for both plots.

**Out:**
- HealthKit import. Manual entry only.
- Body composition fields.
- Target-history visualizations — single target weight only, matching the server.
- Server-computed analytics; iOS owns the math.

## Non-goals

- No new networking layer abstractions. Reuses existing `DietTrackerClient` actor.
- No new theme tokens — only existing `Theme.CTP.*` / `Theme.BG.*` / `Theme.FG.*`.
- No snapshot tests. Existing project doesn't use them.

## Tab dock changes

- `FloatingDock` gains a 4th item: `Weight`, SF Symbol `scalemass`.
- Existing first item label changes from `Log` to `Intake`; symbol unchanged.
- `RootView` adds a 4th `NavigationStack` and routes to `WeightTabRootView`.
- Per existing convention, the dock auto-hides when the Weight stack has pushed views.

## Weight tab structure

`WeightTabRootView` owns:
- A top `Picker(.segmented)` with cases `Log` / `Trends`.
- A switch-on-segment body rendering `WeightLogView` or `WeightTrendsView`.
- A single `NavigationStack` shared between segments. MVP has no push destinations; the stack is present to match the pattern used by the other tabs.

The segmented control sits at the top of the content area, not the bottom — the bottom is owned by the FloatingDock cross-tab nav.

## Section: Log

`Views/Weight/WeightLogView.swift`

**Top card — Today's weigh-in:**
- If `WeightLogModel.todayEntry == nil`: large CTA `Add today's weight` → presents weigh-in editor sheet.
- If present: shows value (formatted in display unit), relative time, tap → editor sheet preloaded with the existing value.

**List — Past entries:**
- Reverse-chronological list of `WeightEntry` excluding today.
- Row: date (`E, MMM d`), weight in display unit, `chevron.right`.
- Swipe-to-delete with `.confirmationDialog` ("Delete weight for {date}?").
- Tap row → editor sheet preloaded with that day's value.

**Editor sheet (`WeightEntrySheet`):**
- Numeric pad input bound to a `Decimal`.
- Segmented `kg` / `lb` picker, defaulting to the user's display-unit preference.
- "Save" button → `WeightLogModel.upsert(date:weight:unit:)`.
- "Delete" button visible only when editing an existing entry.

**Empty state:**
- No entries: `EmptyStateView` with "No weigh-ins yet" + the Add CTA.

## Section: Trends

`Views/Weight/WeightTrendsView.swift`

**Chart 1 — Weight over time** (SwiftUI `Charts`):
- `LineMark` + `PointMark` for each `WeightEntry`, x = date, y = weight in display unit.
- `LineMark` for a 7-day rolling mean (lighter style).
- Horizontal `RuleMark` at target weight when set, labeled.
- Range selector `30d` / `90d` / `1y` / `All`, default `90d`.
- Y-axis auto-scales to a padded min/max around the data.

**Chart 2 — Rate vs kcal regression** (SwiftUI `Charts`):
- `PointMark` per windowed point: x = avg kcal/day, y = lb/week (lb/day × 7), one point per valid 7-day window.
- `LineMark` for the OLS regression line over the visible x range.
- Vertical `RuleMark` at maintenance kcal, labeled.
- Horizontal `RuleMark` at y = 0 (visual reference for maintenance).

**Analytics card** (below the charts):
- Big number: `≈ {maintenance_kcal} kcal/day` with caption `Maintenance`.
- Subline: `Current trend: {±X.X} lb/week` (computed from the last 28 days' OLS weight slope, separate from the windowed regression).
- Subline: `ETA to {target} lb: {date}` / `Trending away from target` / `≈ stable`.
- Confidence chip showing `R² = {value}`: green ≥ 0.5, yellow 0.1–0.5, muted < 0.1 with "low confidence" badge.

**Empty / insufficient states:**
- No weight entries: chart 1 empty state.
- < 14 valid windows: chart 2 hidden; analytics card replaced with a progress meter `Collecting data — N/14 valid weeks` and a one-line explainer.
- No kcal data at all (food entries empty over the range): chart 1 shows; chart 2 hidden with note `Log food to enable correlation`.
- No target set: ETA row reads `Set a target weight in Settings`.

## Settings additions

`Views/SettingsView.swift`

- New section `Weight goal`: target weight input (`Decimal` + `kg`/`lb` picker). Persisted via `PUT /targets` with `target_weight_lb`.
- New toggle `Display unit`: `kg` / `lb`, default `lb`. Stored in `@AppStorage("weight_display_unit")`. Applied to chart axes, list rows, today-card.

## Models

`Models/Weight.swift`:

```swift
enum WeightUnit: String, Codable, CaseIterable { case lb, kg }

struct WeightEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date            // server's log_date
    let weightLb: Double      // stored unit
    let sourceUnit: WeightUnit
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, date = "log_date", weightLb = "weight_lb",
             sourceUnit = "source_unit",
             createdAt = "created_at", updatedAt = "updated_at"
    }
}

struct WeightUpsertBody: Encodable {
    let weight: Decimal
    let unit: WeightUnit
}

struct CaloriesDailyRow: Codable, Hashable {
    let date: Date
    let calories: Int
    enum CodingKeys: String, CodingKey { case date = "log_date", calories }
}
```

`Models/MacroTargets.swift` (extend existing):
- Add `targetWeightLb: Double?` decoded from `target_weight_lb`.

`Util/WeightFormatter.swift`:
- `displayString(lb: Double, in: WeightUnit) -> String` with one-decimal precision.
- `convert(_ value: Decimal, from: WeightUnit, to: WeightUnit) -> Decimal` using `2.20462262`.

## Networking

`Networking/DietTrackerClient.swift` adds:
- `fetchWeightEntries(from: Date, to: Date) async throws -> [WeightEntry]` → `GET /weight?from&to`.
- `upsertWeight(date: Date, weight: Decimal, unit: WeightUnit) async throws -> WeightEntry` → `PUT /weight/{date}`.
- `deleteWeight(date: Date) async throws` → `DELETE /weight/{date}`.
- `fetchCaloriesDaily(from: Date, to: Date) async throws -> [CaloriesDailyRow]` → `GET /calories_daily?from&to`.
- `MacroTargets`-returning endpoints already exist; their decoded type gains `targetWeightLb`.

Errors normalize through existing `DietTrackerError` cases. `notFound` is propagated to the UI as "no entry" rather than an error banner for the today-card load.

## View models

`State/WeightLogModel.swift`:
- `@Observable`, `weak var auth: AuthSession?` (matches existing `WeekModel`/`MonthModel`).
- `LoadState<[WeightEntry]> state`.
- `init(auth:)`; `load()` fetches last 90 days; `upsert(date:weight:unit:)` PUTs and patches the cached list; `delete(date:)` DELETEs and removes.
- `todayEntry: WeightEntry?` computed from the loaded list.

`State/WeightTrendsModel.swift`:
- `@Observable`, `weak var auth: AuthSession?`.
- `LoadState<WeightAnalyticsResult> analytics`.
- `entries: [WeightEntry]` cached for chart 1.
- `targetWeightLb: Double?` from current `MacroTargets`.
- `range: TrendsRange` (`d30 / d90 / y1 / all`), default `d90`.
- `load()` fetches entries + `/calories_daily` in parallel via `async let`, then calls `WeightAnalytics.compute(...)`, then assigns to `analytics`.

## Analytics module

`State/WeightAnalytics.swift` — pure, no `@Observable`, no dependencies on view-model state.

```swift
struct WindowedPoint: Hashable {
    let endDate: Date
    let avgKcal: Double
    let lbPerDay: Double
}

struct Regression: Hashable {
    let slope: Double       // lb/day per kcal
    let intercept: Double   // lb/day
    let rSquared: Double
}

enum ETA: Hashable {
    case date(Date)
    case stable
    case never  // trending away from target
}

struct WeightAnalyticsResult: Hashable {
    let scatter: [WindowedPoint]
    let regression: Regression?
    let maintenanceKcal: Int?
    let trendLbPerWeek: Double?       // last-28-day weight slope × 7
    let etaToTarget: ETA?             // nil if no target set or no data
    let validWindowCount: Int
}

enum WeightAnalytics {
    static func compute(
        entries: [WeightEntry],
        kcal: [CaloriesDailyRow],
        targetWeightLb: Double?,
        today: Date = .now
    ) -> WeightAnalyticsResult
}
```

**Algorithm:**

1. Build `days = [(date, weight_lb?, kcal?)]` for every date in `[min(any input.date), today]`. Gaps allowed.
2. Rolling 7-day windows, stride 1, ending on each day. Window valid if ≥ 5 weight observations AND ≥ 5 kcal observations.
3. For each valid window:
   - `x = mean(kcal values in window)`.
   - `y = OLS slope of weight_lb ~ dayIndex`, using only days with weight values. Units `lb/day`.
   - `endDate = window's last date`.
4. If valid windows < 14 → `regression: nil, maintenanceKcal: nil`.
5. Else OLS over `(x_i, y_i)`. Compute `slope`, `intercept`, `R²`.
6. If `|slope| < 1e-7` → maintenance treated as undefined → `maintenanceKcal: nil`. Else `maintenanceKcal = round(-intercept / slope)`.
7. `trendLbPerWeek` = OLS slope of weight over the last 28 days × 7. Requires ≥ 7 weight observations in that window; otherwise `nil`.
8. ETA:
   - If `targetWeightLb == nil` or `trendLbPerWeek == nil` → `nil`.
   - If `|trendLbPerWeek| < 0.05` → `.stable`.
   - Let `latest_7d_mean_lb` = mean weight in last 7 days (fallback: latest entry).
   - `direction_to_target = targetWeightLb - latest_7d_mean_lb`. If `|direction_to_target| < 0.5` → `.stable` (already at target).
   - If `sign(direction_to_target) != sign(trendLbPerWeek)` → `.never`.
   - Else `daysOut = direction_to_target / (trendLbPerWeek / 7)`; `eta = today + daysOut` → `.date(eta)`.

All math in `Double`. Round half-to-even only on display.

## Theme

- Regression line: `Theme.CTP.mauve`.
- Scatter points: `Theme.CTP.lavender`.
- Weight line (chart 1): `Theme.CTP.blue`.
- 7-day rolling mean: `Theme.CTP.sky`.
- Target rule: `Theme.CTP.green`.
- "Trending away" warning, "low confidence" badge: `Theme.CTP.peach`.
- Cards use existing `.ctpCard()` modifier.

## Errors and edge cases

- Editor sheet: `Save` disabled if weight is `nil`, ≤ 0, or > 2000 lb (sanity cap; the server's 5-year date cap doesn't apply here — sheet always uses today or the row's existing date).
- Networking errors surface as inline banners in each section; existing `.notConfigured` path routes to Settings.
- Editing past entries: the sheet preloads with the row's `sourceUnit` so re-saving without unit change is a no-op on display value.
- Display-unit toggle changes are immediate; raw `weight_lb` doesn't change, so list/chart re-render via the `@AppStorage` change.
- Today-card pull-to-refresh refetches the past 90 days; Trends view's refresh refetches entries + kcal in parallel.

## Testing

`DietTrackerTests/`

**Network layer** (`StubURLProtocol` + JSON fixtures, matches existing pattern):
- `WeightClientTests`
  - Decode `WeightEntry` from fixture (`Fixtures/weight_entries.json`, 5 entries mixing `source_unit`).
  - Decode `CaloriesDailyRow` from fixture.
  - Encode `WeightUpsertBody` (lb and kg variants) and verify URL + body shape.
  - DELETE returns void on 204; 404 → `notFound`; 400 → `server`.
- `TargetsClientTests` extended for `target_weight_lb` round-trip including `null`.

**Analytics** (pure, fixture-free):
- `WeightAnalyticsTests`
  - Constant 2000 kcal/day, weight losing 1 lb/week → maintenance ≈ 2500 (within 100 kcal).
  - Variable kcal with deterministic noise → recovered slope/intercept within tolerance.
  - 13 valid windows → `regression == nil, validWindowCount == 13`.
  - Window with exactly 4 weight-days excluded; 5 included.
  - Stable weight (slope < 0.05 lb/week) → `etaToTarget == .stable`.
  - Trending wrong direction → `etaToTarget == .never`.
  - R² = 1 case (perfect line); R² ≈ 0 case (pure noise).
  - No target set → `etaToTarget == nil`.
- `WeightFormatterTests`
  - kg↔lb conversion round-trip within 0.01 lb.
  - `displayString` for both display units.

**View models** (smoke tests, minimal — pattern is heavy in existing models):
- `WeightLogModelTests`
  - `load()` happy path → `.loaded(entries)`.
  - `upsert(...)` patches the cached list without a refetch.
  - `delete(date:)` removes the entry from the cached list.
- `WeightTrendsModelTests`
  - Parallel fetch composes entries + kcal → calls `WeightAnalytics.compute` once → result lands in `analytics`.

## Out of scope, called out

- HealthKit / scale auto-import.
- Multi-platform sync conflicts (no other client today).
- Plotting in kcal per pound (we deliberately convert to lb/week on display because that's the actionable unit).

## Open questions

None at design time. Settings:
- Display unit default = `lb`, toggle stored in `@AppStorage`.
- Window size = 7 days, fixed.
- Minimum windows = 14, fixed.
- 28-day window for the headline trend, fixed.
