# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Layout

This directory is a workspace containing two independent git repos for one product:

- `pulse-server/` — FastAPI + Postgres backend (single-user today, Google-OAuth gated, MCP endpoint). See its own `AGENTS.md` for commands and architecture.
- `pulse-ios/` — SwiftUI iOS 17+ client that talks to the backend over HTTP. Identity is hardcoded to `user_key = "khash"`; base URL + API key are entered in the app's Settings sheet. See its own `AGENTS.md`.

There is no shared tooling or build at this level — `cd` into the relevant subdirectory before running anything.

## Cross-cutting contract

The two repos are coupled by a JSON-over-HTTP wire format, not a shared schema package. When you change a DTO on one side, you must update the other:

- Server DTOs: `pulse-server/src/diet_tracker_server/models/` (Pydantic, `snake_case`).
- iOS DTOs: `pulse-ios/Pulse/Models/` (Codable structs, camelCase via explicit `CodingKeys` mapping `snake_case` JSON).
- iOS dates use `JSONDecoder.pulseDefault()` which accepts both `YYYY-MM-DD` and ISO-8601 — keep server outputs within those.
- The iOS client appends `?user_key=khash` to every request and sends `X-API-Key`. Server still accepts that for the legacy single-user path; new endpoints should keep working under the session-cookie/Bearer auth path documented in the server `AGENTS.md`.

When extending features that span both sides, read both subprojects' `docs/superpowers/specs/` — that's where cross-cutting design decisions live.
