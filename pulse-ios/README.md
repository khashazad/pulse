# pulse-ios

SwiftUI iOS 17+ client for the self-hosted nutrition / meal-prep tracker. Single-user (identity hardcoded to `user_key = "khash"`); talks JSON over HTTP to [`pulse-server`](../pulse-server).

## What it does

- **Log tab.** Day / week / month / year views of food entries with macro totals, meal grouping, kcal bar charts, macro distribution rings, and a daily-average table on longer ranges.
- **Meals tab.** Browse saved meal templates, view details, log a meal to the current day in one tap.
- **Prep tab.** Tare-aware portion calculator — pick a container, weigh gross, get net grams + macros. CRUD for containers including photo capture/upload.
- **Settings.** Base URL + API key entry (URL → `UserDefaults`, key → Keychain). Sign-in via Google OAuth handled by the server; the app holds a Bearer session.

Dark only, Catppuccin Macchiato palette.

## Architecture

```
Pulse/
├── PulseApp.swift   App entry, AppSettings + AuthSession injection
├── Config/                Constants (user key, defaults), KeychainStore
├── Networking/
│   └── PulseClient.swift   actor over URLSession, ?user_key=khash + X-API-Key
├── Models/                Codable DTOs — camelCase Swift, snake_case JSON via CodingKeys
├── State/                 @Observable view models, no Combine
│                          (DayMacroModel, WeekModel, MonthModel, YearModel,
│                           MealsModel, ContainersListModel, ContainerEditModel,
│                           PrepModel, AppSettings, AuthSession)
├── Theme/                 Catppuccin palette, ctpCard() modifier
└── Views/
    ├── RootView.swift             three NavigationStacks + FloatingDock overlay
    ├── LogView / WeekView / …     Log tab
    ├── MealsView / MealDetailView Meals tab
    ├── Prep/                      Prep tab (PrepView, container CRUD, picker)
    ├── Auth/LoginView.swift
    ├── SettingsView.swift
    └── Components/                rings, bars, rows, AuthorizedAsyncImage
```

**Patterns worth preserving.**

- `@Observable` view models. Each holds `weak var settings: AppSettings?`, calls `settings.makeClient()` on demand, and exposes `LoadState<T>` (`.idle | .loading | .loaded(T) | .failed(PulseError)`).
- `PulseClient` is an `actor`. `JSONDecoder.pulseDefault()` accepts both `YYYY-MM-DD` and ISO-8601. Errors normalized to `PulseError` (notConfigured / unauthorized / notFound / payloadTooLarge / server / network / decoding).
- `PrepModel` stores the whole selected `Container`, not just an id+tare — keeps tare/selection drift impossible.
- `AppSettings.isConfigured` gates the app; when false, `RootView` force-presents `SettingsView(requireConfig: true)` non-dismissibly.
- Container photos go through `AuthorizedAsyncImage` driven by `containerPhotoRequest(id:size:)` (a `nonisolated` factory on the actor), because `AsyncImage` can't add auth headers.
- Theme everything via `Theme.CTP.*` / `Theme.BG.*` / `Theme.FG.*` and `.ctpCard()` — no raw `Color` literals.

## Build

The Xcode project is **generated** from `project.yml` (gitignored). `PULSE_BASE_URL` is baked into the pbxproj literally at generate time; the value lives in `.envrc` at the repo root.

```bash
source .envrc && xcodegen generate
open Pulse.xcodeproj
```

CLI:

```bash
xcodebuild -project Pulse.xcodeproj -scheme Pulse \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

xcodebuild -project Pulse.xcodeproj -scheme Pulse \
  -destination 'platform=iOS Simulator,name=iPhone 15' test

# single test
xcodebuild ... test -only-testing:PulseTests/PrepModelTests/testNetGramsSubtractsTare
```

## Testing

`PulseTests/` uses `StubURLProtocol` injected into an ephemeral `URLSession` to intercept requests and return JSON fixtures from `PulseTests/Fixtures/`. When adding endpoints, add a fixture and a client test rather than mocking the model layer.

## Wire-format contract with the server

Server DTOs in `pulse-server/src/diet_tracker_server/models/` are Pydantic `snake_case`; iOS mirrors them as Codable `camelCase` with explicit `CodingKeys`. Every request appends `?user_key=khash` and sends `X-API-Key` (legacy single-user path), plus the Bearer session token from `AuthSession` on session-auth routes.

## Design docs

`docs/superpowers/specs/` and `docs/superpowers/plans/` capture the brainstorming + implementation plans for shipped features. Read the relevant spec before extending those areas.
