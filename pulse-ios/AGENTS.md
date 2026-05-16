# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project

Single-user iOS client (SwiftUI, iOS 17+, Swift 5.9) for a self-hosted "DietTracker" HTTP backend. The user identity is hardcoded (`Constants.userKey = "khash"`); base URL + API key are entered at runtime via Settings (URL → `UserDefaults`, key → Keychain via `KeychainStore`).

## Commands

The Xcode project is **generated** from `project.yml` and gitignored. Always regenerate before building after pulling or editing `project.yml`:

```bash
xcodegen generate
```

Build / test (CLI):

```bash
xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

xcodebuild -project DietTracker.xcodeproj -scheme DietTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15' test

# single test
xcodebuild ... test -only-testing:DietTrackerTests/PrepModelTests/testNetGramsSubtractsTare
```

The `build/` directory in the repo root is the local DerivedData (gitignored).

## Architecture

**Layers** (`DietTracker/`):

- `Networking/DietTrackerClient.swift` — `actor` wrapping `URLSession`. Every request appends `?user_key=khash` and sets `X-API-Key`. `JSONDecoder.dietTrackerDefault()` accepts both `YYYY-MM-DD` and ISO-8601 dates. Errors are normalized into `DietTrackerError` (notConfigured / unauthorized / notFound / payloadTooLarge / server / network / decoding).
- `Models/` — Codable DTOs mirroring the backend (`DailySummary`, `FoodEntry`, `MealSummary`/`Meal`, `Container`, `MacroTotals`/`MacroTargets`, `PeriodBucket`). `snake_case` JSON ↔ camelCase Swift via explicit `CodingKeys`.
- `State/` — `@Observable` view models (no Combine). Pattern: each model holds a `weak var settings: AppSettings?`, calls `settings.makeClient()` on demand, and exposes a `LoadState<T>` (`.idle | .loading | .loaded(T) | .failed(DietTrackerError)`). Key models: `DayMacroModel`, `WeekModel`, `MonthModel`, `YearModel`, `MealsModel`/`MealDetailModel`, `ContainersListModel`, `ContainerEditModel`, `PrepModel`.
- `Views/` — SwiftUI. `RootView` owns three `NavigationStack`s (one per tab) and a `FloatingDock` overlay; the dock auto-hides when the active stack has pushed views. Tabs: **Log** (day/week/month/year), **Meals** (saved meal templates), **Prep** (tare-based portion calculator + container CRUD with photos).
- `Theme/Theme.swift` — Catppuccin Macchiato palette, dark only. Always style via `Theme.CTP.*` / `Theme.BG.*` / `Theme.FG.*` and the `.ctpCard()` view modifier — don't introduce raw `Color` literals or system grays.
- `Config/` — `Constants` (user key, defaults, keychain identifiers) and `KeychainStore` (Generic Password item with `kSecAttrAccessibleAfterFirstUnlock`).

**State-of-truth conventions worth preserving**:

- `PrepModel` stores the whole selected `Container`, not just an id+tare — keeps tare/selection drift impossible (see comment in file).
- `AppSettings.isConfigured` gates the whole app: when false, `RootView` force-presents `SettingsView(requireConfig: true)` as a non-dismissible sheet.
- Container photo loads use `containerPhotoRequest(id:size:)` (a `nonisolated` factory on the actor) handed to `AuthorizedAsyncImage`, because `AsyncImage` itself can't add headers.

## Testing

`DietTrackerTests/` uses `StubURLProtocol` injected into an ephemeral `URLSession` to intercept requests and return JSON fixtures from `DietTrackerTests/Fixtures/`. When adding endpoints, add a fixture and a client test rather than mocking the model layer.

## Design docs

`docs/superpowers/specs/` and `docs/superpowers/plans/` contain the brainstorming/design + implementation plans for shipped features (nutrition core, meal-prep containers). Read the relevant spec before extending those areas — they capture decisions that aren't in the code.
