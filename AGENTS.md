# AGENTS.md

Canonical agent guidance for this repository lives in **[CLAUDE.md](CLAUDE.md)** — read that file first.

It is the single doc for the whole monorepo and covers:

- the layout (`server/` FastAPI + Postgres backend, `ios/` SwiftUI client) and the cross-cutting JSON-over-HTTP wire contract between them (Bearer-token auth only — no `user_key` query param, no `X-API-Key`);
- per-subproject commands (uv/pytest for the server; xcodegen/xcodebuild for iOS) and architecture (router → service → repository on the server; Views → State → Networking → Models on iOS).

This file is intentionally just a pointer so there is exactly one source of truth; the former per-subproject `CLAUDE.md`/`AGENTS.md` copies drifted and were consolidated into the root `CLAUDE.md`. Keep it that way: update `CLAUDE.md`, not this file.
