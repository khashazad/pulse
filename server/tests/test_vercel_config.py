"""Deployment contract tests for the Vercel-hosted Progress web client."""

from __future__ import annotations

import json
from pathlib import Path

WEB_ROOT = Path(__file__).parents[1] / "web"
BACKEND_ORIGIN = "https://pulse-server-production-4521.up.railway.app"


def test_vercel_routes_web_api_and_oauth_to_production_backend() -> None:
    """Vercel proxies every same-origin web API path and preserves SPA callbacks.

    Returns:
        None: Assertions validate the production deployment contract.

    Raises:
        AssertionError: Raised when the Vercel routing configuration drifts.
    """
    config = json.loads((WEB_ROOT / "vercel.json").read_text())

    assert config["framework"] == "vite"
    assert config["rewrites"] == [
        {
            "source": "/auth/:path*",
            "destination": f"{BACKEND_ORIGIN}/auth/:path*",
        },
        {
            "source": "/measures/:path*",
            "destination": f"{BACKEND_ORIGIN}/measures/:path*",
        },
        {
            "source": "/weight",
            "destination": f"{BACKEND_ORIGIN}/weight",
        },
        {"source": "/login/callback", "destination": "/index.html"},
    ]


def test_server_image_defaults_web_callback_to_vercel_origin() -> None:
    """The Railway image returns successful browser OAuth to the stable Vercel URL.

    Returns:
        None: Assertion validates the public deployment origin.

    Raises:
        AssertionError: Raised when the image no longer defines the web callback origin.
    """
    dockerfile = (WEB_ROOT.parent / "Dockerfile").read_text()

    assert "WEB_APP_URL=https://pulse-progress.vercel.app" in dockerfile


def test_production_web_build_defaults_oauth_start_to_backend_origin() -> None:
    """Production Vite builds always start OAuth on the Railway callback origin.

    Returns:
        None: Assertion validates the committed public production origin.

    Raises:
        AssertionError: Raised when the production OAuth origin is absent or drifts.
    """
    production_env = (WEB_ROOT / ".env.production").read_text()

    assert production_env.splitlines() == [f"VITE_AUTH_ORIGIN={BACKEND_ORIGIN}"]
