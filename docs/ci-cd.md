# CI/CD Pipeline

High-level guide to the GitHub Actions pipeline. All workflows live in
`.github/workflows/` at the repo root (GitHub only reads workflows from there —
per-subproject `.github/` directories are ignored).

## Overview

Every PR and every push to `main` runs lint, type checks, the full test suites,
and a security scan for whichever side of the monorepo changed. Two aggregate
"gate" jobs — `server-gate` and `ios-gate` — summarize everything and are the
only checks meant to be marked *required* in branch protection. Deploys are not
done from CI: Railway auto-deploys `main` and is configured to **wait for CI**,
so a red pipeline blocks the deploy.

```
PR / push to main
├── Server CI ──► ruff ─ mypy ─ unit (3.11+3.12) ─ full suite+coverage ─ docker ──► server-gate
├── iOS CI ─────► swiftlint ─ xcodegen+build+test (simulator) ─────────────────► ios-gate
├── CodeQL (python)          ─ every PR, push to main, weekly
├── Security                 ─ pip-audit, gitleaks, trivy fs, zizmor
├── Dependency Review        ─ PRs only
└── Scorecard                ─ main pushes + weekly
                                                  main green ──► Railway deploys server
```

## Workflows

| Workflow | File | Triggers | What it does |
|---|---|---|---|
| Server CI | `server-ci.yml` | PR / main push touching `server/**` | ruff (lint + format), mypy, unit tests on a 3.11/3.12 matrix, full suite + **80% coverage gate** against `postgres:16` (with alembic migration smoke), Docker build + Trivy image scan + production-mode boot smoke, aggregated by `server-gate` |
| Server CI (skip) | `server-ci-skip.yml` | PRs touching *no* server files | Reports a passing `server-gate` so the required check never deadlocks |
| iOS CI | `ios-ci.yml` | PR / main push touching `ios/**` | SwiftLint `--strict`, then `xcodegen generate` + `xcodebuild test` on a macos-15 runner with a dynamically picked iPhone simulator, aggregated by `ios-gate` |
| iOS CI (skip) | `ios-ci-skip.yml` | PRs touching *no* ios files | Reports a passing `ios-gate` |
| CodeQL | `codeql.yml` | every PR, main push, weekly | Python semantic analysis (`security-extended`). Deliberately *not* path-filtered so it can be a required check |
| Security | `security.yml` | every PR, main push, weekly | `pip-audit` over the exported uv lock, `gitleaks` (full history), Trivy fs/config scan (SARIF → Security tab + CRITICAL/HIGH gate), `zizmor` audit of the workflows themselves |
| Dependency Review | `dependency-review.yml` | PRs | Blocks PRs introducing high-severity vulnerable dependencies; posts a summary comment on failure |
| Scorecard | `scorecard.yml` | main push, weekly | OpenSSF supply-chain posture score → Security tab |

Shared server setup (uv install + `uv sync --frozen --all-extras`) lives in the
composite action `.github/actions/setup-server` — bump the uv pin or sync flags
there, in one place.

## Key design decisions

**Path filtering + skip companions.** Server CI and iOS CI only run for the
side that changed. A path-filtered *required* check would block PRs that don't
trigger it (GitHub waits forever for a check that never reports), so each
pipeline has a skip companion that reports a passing gate on out-of-path PRs.
⚠️ The `paths` list in each real workflow and the `paths-ignore` list in its
skip companion must stay **exact mirrors** — both files carry `KEEP IN SYNC`
markers.

**Gates, not inner jobs.** Branch protection should require exactly:
`server-gate`, `ios-gate`, `CodeQL (python)`, `dependency-review` — never the
inner path-filtered jobs. The gates fail on *any* non-success result
(including `skipped`), so a job silently not running can't pass the gate.

**Python version strategy.** The Docker runtime is `python:3.11-slim`, so the
full suite (unit + integration + coverage) is pinned to 3.11 for production
parity; the unit matrix adds 3.12 as the forward check.

**Production-mode boot smoke.** The Docker job boots the built image with
`APP_ENV=production` and a dummy MCP service token against a real Postgres,
then polls `/health`. Running in production mode means the non-local startup
validators (MCP auth, HTTPS redirect, allowlist) are actually exercised — a
local-mode boot would skip them all.

**Coverage gate.** `fail_under = 80` in `[tool.coverage.report]`
(`server/pyproject.toml`), enforced by the full-suite job. Measured over unit +
integration together (the repositories are integration-covered by design).

**iOS specifics.** The Xcode project is generated in CI
(`PULSE_BASE_URL=https://ci.invalid xcodegen generate`); the simulator is
picked dynamically (hardcoded names break when runner images rotate); the
toolchain is pinned via `DEVELOPER_DIR` (bump it when GitHub retires that Xcode
from the macos-15 image). The job deliberately does **not** pass
`CODE_SIGNING_ALLOWED=NO` — stripping ad-hoc signing breaks the
Keychain-backed `AuthSession` tests. The two `ProgressPhotoStore` upload tests
are timing-sensitive and occasionally flake; a rerun has always cleared them.

**Supply-chain hygiene.** Every third-party action is pinned to a commit SHA
(with a `# vX.Y.Z` comment); workflows run with least-privilege `permissions`
and `persist-credentials: false`; Dependabot keeps three ecosystems current
weekly (grouped): GitHub Actions pins, server Python deps via `uv.lock`, and
the Dockerfile's digest-pinned base images. `zizmor` lints the workflows on
every run. Concurrency cancels superseded PR runs but keys `main` pushes by
SHA so a quick follow-up merge can't cancel the previous commit's checks.

**Trivy escape hatch.** Both Trivy gates (image + fs) honor
`server/.trivyignore`. If a CRITICAL/HIGH CVE in the base image blocks
unrelated PRs before a fixed image is available, add a dated, justified,
expiring entry there; keep the file empty in the steady state.

## Deployment

CI never deploys. Railway watches `main`, and its **Wait for CI** setting holds
the deploy until the commit's checks are green. The push-to-`main` workflow
runs exist precisely to attach those checks to the deployed commit (PR runs
attach to the PR head SHA, not the merge commit).

## Running the same checks locally

```bash
# Server (from server/)
uv run ruff check . && uv run ruff format --check .
uv run mypy src
DATABASE_URL=postgresql://localhost/test USDA_API_KEY=test APP_ENV=test \
  uv run pytest -q -m "not integration"
# Full suite + coverage needs a local Postgres and TEST_DATABASE_URL.

# iOS (from ios/)
swiftlint lint --strict
source .envrc && xcodegen generate
xcodebuild -project Pulse.xcodeproj -scheme Pulse \
  -destination 'platform=iOS Simulator,name=iPhone 16' test

# Workflow linting (from repo root)
actionlint && uvx zizmor .github/workflows/
```

## One-time repo settings (post-merge checklist)

1. **Branch protection** on `main`: require PRs; required status checks =
   `server-gate`, `ios-gate`, `CodeQL (python)`, `dependency-review`.
2. **Code security**: enable secret scanning + push protection (Dependabot
   alerts and the dependency graph are already enabled).
3. **Railway**: enable *Wait for CI* on the server service.
