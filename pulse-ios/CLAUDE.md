# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Single-user iOS client (SwiftUI, iOS 17+, Swift 5.9) for a self-hosted "Pulse" HTTP backend. The user identity is hardcoded (`Constants.userKey = "khash"`); base URL + API key are entered at runtime via Settings (URL → `UserDefaults`, key → Keychain via `KeychainStore`).

**Auth in flight:** `Views/Auth/LoginView.swift` + `State/AuthSession.swift` exist for the migration to the server's session/Bearer flow. The legacy `user_key` + `X-API-Key` path still works; treat both as live until cutover.

**Sibling doc:** `AGENTS.md` at the repo root is the Codex-equivalent. CLAUDE.md is the canonical reference — keep AGENTS.md in sync (or shrink it to a pointer) when editing either.

## Commands

The Xcode project is **generated** from `project.yml` and gitignored. `PULSE_BASE_URL` (required) and `DEVELOPMENT_TEAM` (required for physical-device builds; leave unset for sim-only) must be exported in the shell at generate time — xcodegen bakes them into the pbxproj literally. Values live in `.envrc` at the repo root (gitignored, per-developer). Always regenerate before building after pulling or editing `project.yml`:

```bash
source .envrc && xcodegen generate
```

When asked to "open Xcode" (or similar), run `source .envrc && xcodegen generate && open Pulse.xcodeproj` — never open the project without sourcing `.envrc` first, or builds will fail the prebuild URL check.

Build / test (CLI):

```bash
xcodebuild -project Pulse.xcodeproj -scheme Pulse \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

xcodebuild -project Pulse.xcodeproj -scheme Pulse \
  -destination 'platform=iOS Simulator,name=iPhone 15' test

# single test
xcodebuild ... test -only-testing:PulseTests/PrepModelTests/testNetGramsSubtractsTare
```

The `build/` directory in the repo root is the local DerivedData (gitignored).

## Architecture

**Layers** (`Pulse/`):

- `Networking/PulseClient.swift` — `actor` wrapping `URLSession`. Every request appends `?user_key=khash` and sets `X-API-Key`. `JSONDecoder.pulseDefault()` accepts both `YYYY-MM-DD` and ISO-8601 dates. Errors are normalized into `PulseError` (notConfigured / unauthorized / notFound / payloadTooLarge / server / network / decoding).
- `Models/` — Codable DTOs mirroring the backend: `DailySummary`, `DailyLog`, `FoodEntry`, `Meal`, `Container`, `MacroTotals`/`MacroTargets`, `PeriodBucket`, `CaloriesDailyRow`, `WeightEntry`, `ProgressPhoto`, `WhoAmI`. `snake_case` JSON ↔ camelCase Swift via explicit `CodingKeys`.
- `State/` — `@Observable` view models (no Combine). Pattern: each model holds a `weak var settings: AppSettings?`, calls `settings.makeClient()` on demand, and exposes a `LoadState<T>` (`.idle | .loading | .loaded(T) | .failed(PulseError)`). Models:
  - **Intake:** `DayMacroModel`, `WeekModel`, `MonthModel`, `YearModel`, `DayEntriesGrouping`, `UserTargetsStore`.
  - **Meals:** `MealsModel`.
  - **Prep:** `ContainersListModel`, `ContainerEditModel`, `PrepModel`.
  - **Measures:** `WeightLogModel`, `WeightTrendsModel`, `WeightAnalytics`, `ProgressPhotoStore`, `ProgressPhotoCache`, `ProgressPhotoTagStore`, `PhotoUploadQueue`.
  - **App-wide:** `AppSettings`, `AuthSession`, `LoadState`.
- `Views/` — SwiftUI. `RootView` owns four `NavigationStack`s (one per tab) and a `FloatingDock` overlay; the dock auto-hides when the active stack has pushed views. Tabs (`DockTab` enum):
  - **Intake** (`.intake`) — day/week/month/year macro views (`DayMacroView`, `WeekView`, `MonthView`, `YearView`, `LogView`).
  - **Meals** (`.meals`) — saved meal templates (`MealsView`, `MealDetailView`).
  - **Prep** (`.prep`) — tare-based portion calculator + container CRUD with photos (`Views/Prep/`).
  - **Measures** (`.measures`) — weight log + trends + progress photos with tags + side-by-side comparison + in-app camera (`Views/Measures/`).
  - Subfolders: `Components/` (rings/bars/rows reused across tabs), `Auth/` (`LoginView`).
- `Theme/Theme.swift` — Catppuccin Macchiato palette, dark only. Always style via `Theme.CTP.*` / `Theme.BG.*` / `Theme.FG.*` and the `.ctpCard()` view modifier — don't introduce raw `Color` literals or system grays.
- `Config/` — `Constants` (user key, defaults, keychain identifiers) and `KeychainStore` (Generic Password item with `kSecAttrAccessibleAfterFirstUnlock`).

**State-of-truth conventions worth preserving**:

- `PrepModel` stores the whole selected `Container`, not just an id+tare — keeps tare/selection drift impossible (see comment in file).
- `AppSettings.isConfigured` gates the whole app: when false, `RootView` force-presents `SettingsView(requireConfig: true)` as a non-dismissible sheet.
- Container photo loads use `containerPhotoRequest(id:size:)` (a `nonisolated` factory on the actor) handed to `AuthorizedAsyncImage`, because `AsyncImage` itself can't add headers.

## Testing

`PulseTests/` uses `StubURLProtocol` injected into an ephemeral `URLSession` to intercept requests and return JSON fixtures from `PulseTests/Fixtures/`. When adding endpoints, add a fixture and a client test rather than mocking the model layer.

## Design docs

`docs/superpowers/specs/` and `docs/superpowers/plans/` contain the brainstorming/design + implementation plans for shipped features (nutrition core, meal-prep containers). Read the relevant spec before extending those areas — they capture decisions that aren't in the code.
