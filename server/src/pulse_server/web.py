"""Static delivery for the co-deployed Pulse web client.

The Vite build is copied into :data:`WEB_DIST_DIR` by the production image.
API-only local runs are valid, so a missing build returns an explicit 404
instead of preventing the FastAPI application from starting.
"""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

WEB_DIST_DIR = Path(__file__).with_name("web_dist")
WEB_EXEMPT_PATHS: frozenset[str] = frozenset({"/", "/login/callback"})
WEB_EXEMPT_PREFIXES: tuple[str, ...] = ("/assets/",)


def create_web_router(build_dir: Path = WEB_DIST_DIR) -> APIRouter:
    """Create public routes for the compiled SPA entry point and Vite assets.

    **Inputs:**
    - build_dir (Path): Directory containing ``index.html`` and ``assets/``.

    **Outputs:**
    - APIRouter: Router serving the root, OAuth history fallback, and assets.
    """
    router = APIRouter(include_in_schema=False)
    index_file = build_dir / "index.html"
    assets_dir = (build_dir / "assets").resolve()

    def index_response() -> FileResponse:
        """Return the SPA document or a clear API-only development response.

        **Outputs:**
        - FileResponse: Compiled ``index.html`` response with caching disabled.

        **Exceptions:**
        - HTTPException(404): When the web client has not been built.
        """
        if not index_file.is_file():
            raise HTTPException(status_code=404, detail="Web client is not built")
        return FileResponse(index_file, headers={"Cache-Control": "no-cache"})

    @router.get("/")
    async def web_index() -> FileResponse:
        """Serve the web application's entry document.

        **Outputs:**
        - FileResponse: Compiled SPA entry point.
        """
        return index_response()

    @router.get("/login/callback")
    async def web_login_callback() -> FileResponse:
        """Serve the SPA entry document for direct OAuth callback navigation.

        **Outputs:**
        - FileResponse: Compiled SPA entry point, which processes the query string.
        """
        return index_response()

    @router.get("/assets/{asset_path:path}")
    async def web_asset(asset_path: str) -> FileResponse:
        """Serve one immutable fingerprinted Vite asset from the build directory.

        **Inputs:**
        - asset_path (str): Relative file path below the compiled ``assets`` directory.

        **Outputs:**
        - FileResponse: Requested asset with a one-year immutable cache policy.

        **Exceptions:**
        - HTTPException(404): When the path escapes the asset root or the file is absent.
        """
        candidate = (assets_dir / asset_path).resolve()
        if not candidate.is_relative_to(assets_dir) or not candidate.is_file():
            raise HTTPException(status_code=404, detail="Web asset not found")
        return FileResponse(
            candidate,
            headers={"Cache-Control": "public, max-age=31536000, immutable"},
        )

    return router
