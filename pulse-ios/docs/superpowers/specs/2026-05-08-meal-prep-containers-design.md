# Meal-Prep Containers — Design

**Date:** 2026-05-08
**Status:** Approved (brainstorming)
**Touches:** `diet-tracker-ios` (this repo) + `../dietracker-server` (sibling FastAPI repo)

## Goal

Add reusable **containers** (pots, meal-prep boxes) with a tare weight and a photo, plus a **Prep** screen on iOS that subtracts the tare from a scale reading and divides the remainder into portions. Kitchen tool only — meal prep does not create log entries.

## Scope

In:
- Backend table + REST CRUD + photo upload/serve for `containers`, scoped per `user_key`.
- MCP tools (list/save/update/delete) mirroring the existing nutrition-server MCP pattern. No photo over MCP.
- iOS `Prep` tab in the dock with a calculator and a containers manager (CRUD + camera/library photo).
- Auth and error model reuse the existing `X-API-Key` + `DietTrackerError` patterns.

Out (v1, may add later):
- Multiple photos per container.
- Capacity / category / notes fields.
- Auto-logging prepped portions to future days.
- Per-portion macro computation (would push into food-logging territory).
- Cross-user sharing.

## Server: data model

New table `containers`:

| col | type | notes |
|---|---|---|
| `id` | uuid pk | `gen_random_uuid()` |
| `user_key` | text not null | scopes to user |
| `name` | text not null | e.g. "Big Pyrex pot" |
| `normalized_name` | text not null | lowercased, whitespace-collapsed; unique per user |
| `tare_weight_g` | numeric not null | grams; CHECK > 0 |
| `photo` | bytea null | full-size JPEG (≤1600 px long edge, q=82) |
| `photo_thumb` | bytea null | thumbnail JPEG (256 px long edge) |
| `photo_mime` | text null | always `image/jpeg` for v1 |
| `created_at` | timestamptz not null default `now()` | |
| `updated_at` | timestamptz not null default `now()` | bumped app-side on every UPDATE (matches existing `meals`/`custom_foods` pattern) |

Indexes:
- `(user_key, normalized_name)` UNIQUE.
- `(user_key)`.

Alembic revision: `20260508_000001_containers.py`. No data backfill.

## Server: API surface

All routes require `X-API-Key`. All accept `?user_key=…` (defaults to server's default user).

| Method + path | Body | Returns |
|---|---|---|
| `GET /containers` | — | `{ containers: ContainerSummary[] }` — id, name, tare_weight_g, has_photo, updated_at; **never** the bytes |
| `POST /containers` | JSON `{ name, tare_weight_g }` | `Container` — same shape; `has_photo: false` |
| `GET /containers/{id}` | — | `Container` |
| `PATCH /containers/{id}` | JSON partial `{ name?, tare_weight_g? }` | `Container` |
| `DELETE /containers/{id}` | — | 204 |
| `PUT /containers/{id}/photo` | multipart `file=…` (image/*) | `{ has_photo: true }`. Server resizes to 1600 px (full) and 256 px (thumb), re-encodes to JPEG q=82, writes both columns. Strips EXIF. |
| `DELETE /containers/{id}/photo` | — | 204; clears both photo columns |
| `GET /containers/{id}/photo` | `?size=full\|thumb` (default `thumb`) | body: `image/jpeg`; headers: `Cache-Control: private, max-age=86400`, `ETag: "<updated_at>"` |

Validation:
- Upload rejected if `Content-Length > 10 MB` or Pillow can't decode → `415` / `413` as appropriate.
- Duplicate `(user_key, normalized_name)` → `409` from unique violation.
- `tare_weight_g <= 0` → `422`.

MCP tools (in `mcp/server.py`, mirroring existing pattern):
- `list_containers()`
- `save_container(name, tare_weight_g)`
- `update_container(id, name?, tare_weight_g?)`
- `delete_container(id)`

No MCP photo handling — bytes are awkward over MCP.

## Server: code layout

Mirror the existing per-resource layout:
- `nutrition_server/models/containers.py` — Pydantic `ContainerCreate / ContainerUpdate / Container / ContainerSummary / ContainersListResponse`.
- `nutrition_server/repositories/containers.py` — async SQLAlchemy queries; never selects blobs in `list_*`/`get_*` summaries unless asked.
- `nutrition_server/routers/containers.py` — `APIRouter(dependencies=[Depends(require_api_key)])`. Image processing done inline with Pillow; add `Pillow` to `pyproject.toml`.
- `nutrition_server/mcp/server.py` — register the four MCP tools next to existing ones.
- `nutrition_server/app.py` — `app.include_router(containers.router, prefix="/containers", tags=["containers"])`.

## iOS: data flow

Models in `DietTracker/Models/`:
- `Container.swift` — `id: UUID, name: String, tareWeightG: Decimal, hasPhoto: Bool, updatedAt: Date`.
- `ContainerSummary.swift` — same minus `updatedAt` if not needed in lists; in practice keep identical.
- `ContainerPhotoSize.swift` — `enum { case thumb, full; var query: String }`.

Networking — extend `DietTrackerClient`:
- `func listContainers() async throws -> [ContainerSummary]`
- `func getContainer(id: UUID) async throws -> Container`
- `func createContainer(name: String, tareWeightG: Decimal) async throws -> Container`
- `func updateContainer(id: UUID, name: String?, tareWeightG: Decimal?) async throws -> Container`
- `func deleteContainer(id: UUID) async throws`
- `func uploadContainerPhoto(id: UUID, jpegData: Data) async throws`
- `func deleteContainerPhoto(id: UUID) async throws`
- `func containerPhotoRequest(id: UUID, size: ContainerPhotoSize) -> URLRequest` — pre-built request including `X-API-Key` header so views can fetch via `URLSession` with caching.

Image rendering — small new view `Views/Prep/ContainerPhotoView.swift`:
- Wraps a `URLSession` data task; caches in shared `URLCache(memoryCapacity: 16MB, diskCapacity: 64MB)`.
- States: `placeholder → loading → loaded(UIImage) → failed`.

State (`@Observable`):
- `PrepModel` — `selectedContainerId: UUID?, totalGrams: Decimal?, portions: Int = 1`. Computed `netGrams`, `perPortionGrams`. Persists `lastContainerId` to `UserDefaults`.
- `ContainersListModel` — `LoadState<[ContainerSummary]>` with `load()`, `delete(id)`.
- `ContainerEditModel` — form fields, `dirty`, `save()` that does `create` (or `update`) then `uploadContainerPhoto` if a new image was picked.

Views under `DietTracker/Views/Prep/`:
- `PrepView.swift` — calculator (selector + total weight + portions stepper + computed net/per-portion).
- `ContainerPickerSheet.swift` — list-style picker presented from PrepView; tap row → dismiss + set selection.
- `ContainersListView.swift` — list with thumb + name + tare; `+` to add; tap → edit; swipe to delete.
- `ContainerEditView.swift` — photo + name + tare; "Take Photo" / "Choose from Library" / "Remove" sheet; Save/Cancel.

`RootView` changes:
- Existing `Tab` enum gains `.prep`.
- Top-level switch adds `case .prep: PrepView()`.
- `FloatingDock` gains a sixth tile. If layout becomes cramped, the calendar tile collapses into the per-screen toolbar (matches the Macchiato-redesign pattern).

`Info.plist`: add `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription`.

## iOS: error handling

Reuse `DietTrackerError`; add `case payloadTooLarge` for HTTP 413.

Per-screen states:
- **PrepView, no containers** → `ContentUnavailableView("No containers yet", systemImage: "cube.box", description: …, action: "Add a container")` linking to `ContainerEditView`.
- **PrepView, container fetch failure** → inline error banner with Retry.
- **ContainersListView** → standard `LoadState` pattern (loading / loaded / empty / failed).
- **ContainerEditView, save failure** → inline error under Save button; form stays dirty.

No retries, no offline cache (matches existing app).

## iOS: math

```
net          = max(0, totalGrams - tareWeightG)
perPortion   = portions > 0 ? net / portions : net
```
- Display rounds to nearest gram.
- Negative-net case (scale lighter than tare): show net as `0` and a soft hint "Total looks lighter than the container".

## Testing

Backend (pytest):
- CRUD happy path including duplicate-name conflict.
- Photo upload, fetch (thumb + full), delete-photo, ensure list endpoint never returns blobs.
- 401 without key; 404 for unknown id; 422 for `tare_weight_g <= 0`.

iOS:
- Decoding fixtures: `containers.json` (list) and `container.json` (single).
- `PrepModel` unit test: `total=1450, tare=412, portions=5 → net=1038, per≈208`.
- `PrepModel` edge case: `total < tare → net=0`.

No UI tests; SwiftUI Previews only (matches existing app).

## Configuration & secrets

Nothing new. Reuses existing `X-API-Key` + `user_key` constants.

## Migration & rollout

1. Land backend (migration, router, MCP, tests). Deploy to Railway.
2. Land iOS feature on a feature branch off `main`. Verify against deployed backend.
3. Old iOS clients see no change. New iOS clients against an old backend get 404 on `listContainers` — Prep tab shows empty state.

## Open items

None blocking. Future items already captured under "Out of scope".
