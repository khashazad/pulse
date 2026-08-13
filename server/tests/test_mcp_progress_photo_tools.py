"""Unit tests for MCP bulk progress-photo upload behavior."""

from __future__ import annotations

import base64
import io
import uuid
from contextlib import asynccontextmanager
from datetime import UTC
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from unittest.mock import AsyncMock, MagicMock, call, patch
from zoneinfo import ZoneInfo

import pytest
from fastmcp import Client, FastMCP
from fastmcp.exceptions import ToolError
from PIL import Image

from pulse_server.mcp.context import ToolContext
from pulse_server.mcp.tools import progress_photo_tools


def _jpeg_bytes(*, exif_date: str | None = None) -> bytes:
    """Build a small JPEG fixture with an optional EXIF DateTimeOriginal value.

    **Inputs:**
    - exif_date (str | None): EXIF timestamp to write into DateTimeOriginal, or
      ``None`` to omit capture-date metadata.

    **Outputs:**
    - bytes: Encoded JPEG bytes.
    """
    img = Image.new("RGB", (32, 32), color=(210, 120, 80))
    buf = io.BytesIO()
    if exif_date is None:
        img.save(buf, format="JPEG")
    else:
        exif = Image.Exif()
        exif[36867] = exif_date
        img.save(buf, format="JPEG", exif=exif)
    return buf.getvalue()


def _png_bytes() -> bytes:
    """Build a small PNG fixture without capture-date metadata.

    **Outputs:**
    - bytes: Encoded PNG bytes.
    """
    img = Image.new("RGB", (32, 32), color=(80, 120, 210))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _b64(raw: bytes) -> str:
    """Base64-encode raw fixture bytes for MCP JSON arguments.

    **Inputs:**
    - raw (bytes): Image bytes.

    **Outputs:**
    - str: ASCII base64 payload.
    """
    return base64.b64encode(raw).decode("ascii")


def _tag_row(name: str, order: int = 0, tag_id: uuid.UUID | None = None) -> dict:
    """Build a progress-photo tag row fixture.

    **Inputs:**
    - name (str): Display and normalized tag name.
    - order (int): Sort order.
    - tag_id (uuid.UUID | None): Optional fixed id.

    **Outputs:**
    - dict: Row-shaped tag mapping.
    """
    now = DateTimeValue(2026, 5, 1, 12, 0, tzinfo=UTC)
    return {
        "id": tag_id or uuid.uuid4(),
        "user_key": "khash",
        "name": name,
        "normalized_name": name.lower(),
        "sort_order": order,
        "created_at": now,
        "updated_at": now,
    }


def _photo_row(*, photo_id: uuid.UUID, tag_id: uuid.UUID, log_date: DateValue) -> dict:
    """Build a progress-photo repository row fixture.

    **Inputs:**
    - photo_id (uuid.UUID): Stored photo id.
    - tag_id (uuid.UUID): Selected tag id.
    - log_date (DateValue): Date assigned to the photo.

    **Outputs:**
    - dict: Row-shaped progress-photo mapping.
    """
    now = DateTimeValue(2026, 5, 18, 12, 0, tzinfo=UTC)
    return {
        "id": photo_id,
        "user_key": "khash",
        "log_date": log_date,
        "tag_id": tag_id,
        "photo_mime": "image/jpeg",
        "bytes": 123,
        "sha256": "abc123",
        "storage_key_prefix": f"progress/khash/{photo_id}",
        "created_at": now,
        "updated_at": now,
    }


def test_extract_capture_date_reads_exif_datetime_original() -> None:
    """EXIF DateTimeOriginal is used as the capture date when present."""
    raw = _jpeg_bytes(exif_date="2026:05:17 08:15:30")

    resolved = progress_photo_tools.resolve_capture_date(
        raw=raw,
        provided_date=None,
        default_date=None,
        filename="front.jpg",
    )

    assert resolved.value == DateValue(2026, 5, 17)
    assert resolved.source == "metadata"


def test_resolve_capture_date_uses_per_photo_fallback_when_metadata_missing() -> None:
    """A per-photo capture_date is used when the file lacks image date metadata."""
    resolved = progress_photo_tools.resolve_capture_date(
        raw=_png_bytes(),
        provided_date="2026-05-18",
        default_date=None,
        filename="front.png",
    )

    assert resolved.value == DateValue(2026, 5, 18)
    assert resolved.source == "provided"


def test_resolve_capture_date_requires_metadata_or_fallback_date() -> None:
    """A photo with no metadata and no fallback date is rejected."""
    with pytest.raises(ToolError, match="capture date"):
        progress_photo_tools.resolve_capture_date(
            raw=_png_bytes(),
            provided_date=None,
            default_date=None,
            filename="front.png",
        )


def test_select_progress_photo_tag_prefers_longest_existing_tag_match() -> None:
    """A richer existing tag wins over its shorter substring tag."""
    front = _tag_row("front", 0)
    flexed = _tag_row("flexed front", 1)

    match = progress_photo_tools.select_progress_photo_tag(
        [front, flexed],
        pose_hint="Flexed Front",
        filename="IMG_0012.jpg",
        metadata_text=[],
    )

    assert match.tag["id"] == flexed["id"]
    assert match.source == "pose_hint"


@pytest.mark.asyncio
async def test_upload_progress_photos_handles_multi_date_and_delegates_to_insert_one() -> None:
    """The MCP bulk tool resolves dates/tags and calls the existing upload service."""
    front = _tag_row("front", 0, uuid.UUID("00000000-0000-0000-0000-0000000000f1"))
    flexed = _tag_row("flexed front", 1, uuid.UUID("00000000-0000-0000-0000-0000000000f2"))
    calls: list[dict] = []

    @asynccontextmanager
    async def _session_ctx():
        """Yield a fake DB session for the tool body.

        **Outputs:**
        - AsyncIterator[MagicMock]: Fake session object.
        """
        yield MagicMock()

    @asynccontextmanager
    async def _tx(_session):
        """No-op transaction context for the tool unit test.

        **Inputs:**
        - _session: Ignored fake session.

        **Outputs:**
        - AsyncIterator[None]: Empty transaction body.
        """
        yield

    async def _insert_one(**kwargs):
        """Capture the service call and echo a persisted row.

        **Inputs:**
        - **kwargs: Arguments passed to ``insert_one``.

        **Outputs:**
        - dict: Row-shaped progress-photo mapping.
        """
        calls.append(kwargs)
        return _photo_row(
            photo_id=uuid.uuid4(),
            tag_id=kwargs["tag_id"],
            log_date=kwargs["log_date"],
        )

    tag_repo = MagicMock()
    tag_repo.list_for_user = AsyncMock(return_value=[front, flexed])
    mcp = FastMCP("test-progress-photos")
    ctx = ToolContext(user_key="khash", tz=ZoneInfo("America/Toronto"), usda_getter=MagicMock())
    progress_photo_tools.register(mcp, ctx)

    with (
        patch(
            "pulse_server.mcp.tools.progress_photo_tools.get_session", return_value=_session_ctx()
        ),
        patch("pulse_server.mcp.tools.progress_photo_tools.transaction", side_effect=_tx),
        patch(
            "pulse_server.mcp.tools.progress_photo_tools.ProgressPhotoTagRepository",
            return_value=tag_repo,
        ),
        patch(
            "pulse_server.mcp.tools.progress_photo_tools.ProgressPhotoRepository",
            return_value=MagicMock(),
        ),
        patch(
            "pulse_server.mcp.tools.progress_photo_tools.get_photo_store", return_value=MagicMock()
        ),
        patch(
            "pulse_server.mcp.tools.progress_photo_tools.insert_one", side_effect=_insert_one
        ) as insert_mock,
    ):
        async with Client(mcp) as client:
            result = await client.call_tool(
                "upload_progress_photos",
                {
                    "photos": [
                        {
                            "image_base64": _b64(_jpeg_bytes(exif_date="2026:05:17 08:15:30")),
                            "filename": "front.jpg",
                        },
                        {
                            "image_base64": _b64(_png_bytes()),
                            "filename": "ignored-name.png",
                            "capture_date": "2026-05-18",
                            "pose_hint": "Flexed Front",
                        },
                    ]
                },
            )

    payload = result.structured_content
    assert payload["accepted_count"] == 2
    assert payload["rejected_count"] == 0
    assert [p["date"] for p in payload["accepted"]] == ["2026-05-17", "2026-05-18"]
    assert [p["tag"]["name"] for p in payload["accepted"]] == ["front", "flexed front"]
    assert [c["log_date"] for c in calls] == [DateValue(2026, 5, 17), DateValue(2026, 5, 18)]
    assert [c["tag_id"] for c in calls] == [front["id"], flexed["id"]]
    assert [c["raw"] for c in calls] == [
        _jpeg_bytes(exif_date="2026:05:17 08:15:30"),
        _png_bytes(),
    ]
    insert_mock.assert_has_awaits([call(**calls[0]), call(**calls[1])])


@pytest.mark.asyncio
async def test_upload_progress_photos_keeps_rejections_per_photo() -> None:
    """One bad photo does not prevent a later valid photo from being accepted."""
    front = _tag_row("front", 0)

    @asynccontextmanager
    async def _session_ctx():
        """Yield a fake DB session for the tool body.

        **Outputs:**
        - AsyncIterator[MagicMock]: Fake session object.
        """
        yield MagicMock()

    @asynccontextmanager
    async def _tx(_session):
        """No-op transaction context for the tool unit test.

        **Inputs:**
        - _session: Ignored fake session.

        **Outputs:**
        - AsyncIterator[None]: Empty transaction body.
        """
        yield

    async def _insert_one(**kwargs):
        """Echo a persisted row for accepted uploads.

        **Inputs:**
        - **kwargs: Arguments passed to ``insert_one``.

        **Outputs:**
        - dict: Row-shaped progress-photo mapping.
        """
        return _photo_row(
            photo_id=uuid.uuid4(),
            tag_id=kwargs["tag_id"],
            log_date=kwargs["log_date"],
        )

    tag_repo = MagicMock()
    tag_repo.list_for_user = AsyncMock(return_value=[front])
    mcp = FastMCP("test-progress-photos")
    ctx = ToolContext(user_key="khash", tz=ZoneInfo("America/Toronto"), usda_getter=MagicMock())
    progress_photo_tools.register(mcp, ctx)

    with (
        patch(
            "pulse_server.mcp.tools.progress_photo_tools.get_session", return_value=_session_ctx()
        ),
        patch("pulse_server.mcp.tools.progress_photo_tools.transaction", side_effect=_tx),
        patch(
            "pulse_server.mcp.tools.progress_photo_tools.ProgressPhotoTagRepository",
            return_value=tag_repo,
        ),
        patch(
            "pulse_server.mcp.tools.progress_photo_tools.ProgressPhotoRepository",
            return_value=MagicMock(),
        ),
        patch(
            "pulse_server.mcp.tools.progress_photo_tools.get_photo_store", return_value=MagicMock()
        ),
        patch("pulse_server.mcp.tools.progress_photo_tools.insert_one", side_effect=_insert_one),
    ):
        async with Client(mcp) as client:
            result = await client.call_tool(
                "upload_progress_photos",
                {
                    "photos": [
                        {
                            "image_base64": _b64(_png_bytes()),
                            "filename": "front.png",
                        },
                        {
                            "image_base64": _b64(_png_bytes()),
                            "filename": "front.png",
                            "capture_date": "2026-05-18",
                        },
                    ]
                },
            )

    payload = result.structured_content
    assert payload["accepted_count"] == 1
    assert payload["rejected_count"] == 1
    assert payload["accepted"][0]["date"] == "2026-05-18"
    assert payload["rejected"][0]["index"] == 0
    assert "capture date" in payload["rejected"][0]["reason"]
