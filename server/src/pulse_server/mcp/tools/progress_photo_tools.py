"""MCP tools for progress-photo tags and bulk image upload.

The REST upload endpoint requires an explicit ``log_date`` and ``tag_id``.
MCP callers, especially ChatGPT mobile, naturally start from image files. This
module bridges that gap by extracting capture dates from image metadata when it
can, resolving an existing progress-photo tag from text signals, and then
delegating every accepted image to
:func:`pulse_server.services.progress_photo_service.insert_one` so validation,
processing, object-store persistence, and row insertion stay on the canonical
API path.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import io
import ipaddress
import re
import socket
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from datetime import date as DateValue
from pathlib import PurePath
from typing import Annotated, Any, Literal, Protocol, TypeVar
from urllib.parse import urljoin, urlsplit
from uuid import NAMESPACE_URL, UUID, uuid5

import httpx
from fastapi import HTTPException
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from PIL import Image, UnidentifiedImageError
from pydantic import Field

from pulse_server.db import get_session, transaction
from pulse_server.mcp.context import ToolContext, parse_iso_date
from pulse_server.mcp.models import (
    ChatGPTProgressPhotoFile,
    ProgressPhotoBulkUploadResponse,
    ProgressPhotoTagMatch,
    ProgressPhotoTagsResponse,
    ProgressPhotoUploadAccepted,
    ProgressPhotoUploadItem,
    ProgressPhotoUploadRejected,
)
from pulse_server.models.progress_photo import ProgressPhotoMetadata, ProgressPhotoTagResponse
from pulse_server.photo_store import get_photo_store
from pulse_server.repositories.progress_photo import ProgressPhotoRepository
from pulse_server.repositories.progress_photo_tag import ProgressPhotoTagRepository
from pulse_server.services.progress_photo_service import MAX_UPLOAD_BYTES, insert_one
from pulse_server.services.progress_photo_tag_service import list_tags

CaptureDateSource = Literal["metadata", "provided", "default"]
TagMatchSource = Literal["pose_hint", "filename", "metadata"]

_TOKEN_RE = re.compile(r"[a-z0-9]+")
_EXIF_CAPTURE_DATE_TAGS = (36867, 36868, 306)
_EXIF_TEXT_TAGS = (270, 40091, 40092, 40094, 40095, 37510)
_INFO_DATE_KEYS = (
    "DateTimeOriginal",
    "DateTimeDigitized",
    "DateTime",
    "CreateDate",
    "CreationTime",
    "creation_time",
    "date:create",
    "date:modify",
)
_INFO_TEXT_KEYS = (
    "Title",
    "Description",
    "Comment",
    "Keywords",
    "Subject",
    "ImageDescription",
    "UserComment",
    "pose",
    "tag",
)
_DOWNLOAD_CHUNK_BYTES = 64 * 1024
_MAX_DOWNLOAD_REDIRECTS = 3
_DOWNLOAD_TIMEOUT = httpx.Timeout(20.0, connect=5.0)


class _ProgressPhotoSource(Protocol):
    """Structural fields shared by base64 and ChatGPT file upload items."""

    capture_date: str | None
    pose_hint: str | None
    idempotency_key: str | None


SourceT = TypeVar("SourceT", bound=_ProgressPhotoSource)
RawLoader = Callable[[SourceT], Awaitable[bytes]]
FilenameGetter = Callable[[SourceT], str | None]
IdempotencyGetter = Callable[[SourceT], str | None]


@dataclass(frozen=True)
class CaptureDateResolution:
    """Resolved capture date plus the source that supplied it.

    **Inputs:**
    - value (DateValue): Calendar date to file the photo under.
    - source (CaptureDateSource): ``metadata`` when extracted from image
      metadata, ``provided`` when the per-photo fallback was used, or
      ``default`` when the batch fallback was used.
    """

    value: DateValue
    source: CaptureDateSource


@dataclass(frozen=True)
class TagResolution:
    """Resolved tag row plus the text source that matched it.

    **Inputs:**
    - tag (dict[str, Any]): Existing ``progress_photo_tags`` row selected for
      the image.
    - source (TagMatchSource): Text signal that produced the match.
    """

    tag: dict[str, Any]
    source: TagMatchSource


def _row_to_tag_response(row: dict[str, Any]) -> ProgressPhotoTagResponse:
    """Project a tag row into the same DTO used by the REST tag endpoint.

    **Inputs:**
    - row (dict[str, Any]): Column→value mapping from
      :class:`ProgressPhotoTagRepository`.

    **Outputs:**
    - ProgressPhotoTagResponse: Typed tag response.
    """
    return ProgressPhotoTagResponse(
        id=row["id"],
        name=row["name"],
        normalized_name=row["normalized_name"],
        sort_order=row["sort_order"],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


def _row_to_photo_metadata(row: dict[str, Any]) -> ProgressPhotoMetadata:
    """Project a progress-photo row into the REST metadata DTO.

    **Inputs:**
    - row (dict[str, Any]): Column→value mapping returned by
      :class:`ProgressPhotoRepository`.

    **Outputs:**
    - ProgressPhotoMetadata: Typed metadata response for the stored photo.
    """
    return ProgressPhotoMetadata(
        id=row["id"],
        date=row["log_date"],
        tag_id=row["tag_id"],
        mime=row["photo_mime"],
        bytes=row["bytes"],
        sha256=row["sha256"],
        updated_at=row["updated_at"],
    )


def _filename_label(filename: str | None) -> str:
    """Return a safe, short label for user-facing per-photo errors.

    **Inputs:**
    - filename (str | None): Caller-supplied filename, if any.

    **Outputs:**
    - str: Basename label or ``"photo"`` when absent.
    """
    if not filename:
        return "photo"
    return PurePath(filename).name or "photo"


def decode_image_base64(value: str) -> bytes:
    """Decode an MCP image argument from raw base64 or a data URL.

    **Inputs:**
    - value (str): Base64 text, optionally prefixed as a data URL.

    **Outputs:**
    - bytes: Decoded image payload.

    **Exceptions:**
    - ToolError: Raised when the payload is not valid base64 or decodes to
      empty bytes.
    """
    stripped = value.strip()
    payload = stripped
    if stripped.lower().startswith("data:"):
        header, separator, data = stripped.partition(",")
        normalized_header = header.lower()
        if (
            not separator
            or not normalized_header.startswith("data:image/")
            or not normalized_header.endswith(";base64")
        ):
            raise ToolError("image_base64 data URLs must be an image data URL using base64")
        payload = data
    compact = re.sub(r"\s+", "", payload)
    try:
        raw = base64.b64decode(compact, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ToolError("image_base64 must be valid base64 image data") from exc
    if not raw:
        raise ToolError("image_base64 decoded to empty bytes")
    return raw


async def _validate_public_https_url(value: str) -> None:
    """Reject attachment URLs that could target private server-side resources.

    **Inputs:**
    - value (str): Candidate ChatGPT temporary download URL.

    **Outputs:**
    - None: The URL is an HTTPS URL whose current DNS answers are public.

    **Exceptions:**
    - ToolError: Raised for malformed URLs, non-HTTPS URLs, embedded
      credentials, nonstandard ports, DNS failures, or non-public addresses.
    """
    parsed = urlsplit(value)
    try:
        port = parsed.port
    except ValueError as exc:
        raise ToolError("ChatGPT attachment download_url must be a public HTTPS URL") from exc
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or port not in (None, 443)
    ):
        raise ToolError("ChatGPT attachment download_url must be a public HTTPS URL")
    try:
        addresses = await asyncio.to_thread(
            socket.getaddrinfo,
            parsed.hostname,
            443,
            type=socket.SOCK_STREAM,
        )
    except OSError as exc:
        raise ToolError("ChatGPT attachment download host could not be resolved") from exc
    if not addresses or any(
        not ipaddress.ip_address(address[4][0]).is_global for address in addresses
    ):
        raise ToolError("ChatGPT attachment download_url must be a public HTTPS URL")


async def _download_chatgpt_file_with_client(
    file: ChatGPTProgressPhotoFile,
    client: httpx.AsyncClient,
) -> bytes:
    """Download one ChatGPT file parameter through a bounded HTTP client.

    Every redirect target is revalidated before it is requested. The response
    is streamed under the same byte limit used by the canonical REST upload.

    **Inputs:**
    - file (ChatGPTProgressPhotoFile): File reference injected by ChatGPT.
    - client (httpx.AsyncClient): Client configured without automatic redirects.

    **Outputs:**
    - bytes: Downloaded image payload within ``MAX_UPLOAD_BYTES``.

    **Exceptions:**
    - ToolError: Raised when the URL is unsafe, the download fails, redirects
      are invalid/excessive, the media type is not an image, or the byte cap is
      exceeded.
    """
    current_url = file.download_url
    try:
        for redirect_index in range(_MAX_DOWNLOAD_REDIRECTS + 1):
            await _validate_public_https_url(current_url)
            async with client.stream(
                "GET",
                current_url,
                headers={"Accept": "image/*"},
            ) as response:
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location or redirect_index == _MAX_DOWNLOAD_REDIRECTS:
                        raise ToolError("ChatGPT attachment download redirected too many times")
                    current_url = urljoin(current_url, location)
                    continue
                response.raise_for_status()
                response_mime = response.headers.get("content-type", "").split(";", 1)[0]
                declared_mime = file.mime_type or ""
                if not response_mime.startswith("image/") and not declared_mime.startswith(
                    "image/"
                ):
                    raise ToolError("ChatGPT attachment is not an image")
                content_length = response.headers.get("content-length")
                if content_length is not None:
                    try:
                        declared_bytes = int(content_length)
                    except ValueError:
                        declared_bytes = 0
                    if declared_bytes > MAX_UPLOAD_BYTES:
                        raise ToolError(f"ChatGPT attachment exceeds {MAX_UPLOAD_BYTES}-byte cap")
                payload = bytearray()
                async for chunk in response.aiter_bytes(_DOWNLOAD_CHUNK_BYTES):
                    if len(payload) + len(chunk) > MAX_UPLOAD_BYTES:
                        raise ToolError(f"ChatGPT attachment exceeds {MAX_UPLOAD_BYTES}-byte cap")
                    payload.extend(chunk)
                if not payload:
                    raise ToolError("ChatGPT attachment downloaded as an empty file")
                return bytes(payload)
    except ToolError:
        raise
    except httpx.HTTPError as exc:
        raise ToolError("Could not download ChatGPT attachment") from exc
    raise ToolError("Could not download ChatGPT attachment")


async def download_chatgpt_file(file: ChatGPTProgressPhotoFile) -> bytes:
    """Download one ChatGPT attachment using the production HTTP policy.

    **Inputs:**
    - file (ChatGPTProgressPhotoFile): File reference injected by ChatGPT.

    **Outputs:**
    - bytes: Downloaded image bytes.

    **Exceptions:**
    - ToolError: Propagated from URL validation or bounded downloading.
    """
    async with httpx.AsyncClient(timeout=_DOWNLOAD_TIMEOUT, follow_redirects=False) as client:
        return await _download_chatgpt_file_with_client(file, client)


def _metadata_value_to_text(value: Any) -> str | None:
    """Convert a Pillow metadata value into searchable text.

    **Inputs:**
    - value (Any): EXIF or ``Image.info`` value.

    **Outputs:**
    - str | None: Decoded text, or ``None`` when the value has no useful text.
    """
    if value is None:
        return None
    if isinstance(value, bytes):
        raw = value.strip(b"\x00")
        if raw.startswith(b"ASCII\x00\x00\x00"):
            raw = raw[8:]
        for encoding in ("utf-8", "utf-16le", "latin-1"):
            try:
                text = raw.decode(encoding).strip("\x00").strip()
            except UnicodeDecodeError:
                continue
            if text:
                return text
        return None
    if isinstance(value, tuple | list):
        try:
            return bytes(value).decode("utf-16le").strip("\x00").strip()
        except (TypeError, ValueError, UnicodeDecodeError):
            return " ".join(str(v) for v in value if v is not None).strip() or None
    text = str(value).strip()
    return text or None


def _date_from_text(value: Any) -> DateValue | None:
    """Parse a date from EXIF-ish or ISO-ish metadata text.

    **Inputs:**
    - value (Any): Raw metadata value.

    **Outputs:**
    - DateValue | None: Parsed date, or ``None`` when no supported date shape
      is present.
    """
    text = _metadata_value_to_text(value)
    if not text:
        return None
    exif_match = re.search(r"\b(\d{4}):(\d{2}):(\d{2})(?:\s+\d{2}:\d{2}:\d{2})?\b", text)
    if exif_match:
        year, month, day = (int(part) for part in exif_match.groups())
        try:
            return DateValue(year, month, day)
        except ValueError:
            return None
    iso_match = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", text)
    if iso_match:
        try:
            return DateValue.fromisoformat(iso_match.group(1))
        except ValueError:
            return None
    return None


def _open_image(raw: bytes) -> Image.Image | None:
    """Open image bytes with Pillow, returning ``None`` for undecodable files.

    **Inputs:**
    - raw (bytes): Candidate image bytes.

    **Outputs:**
    - Image.Image | None: Pillow image object, or ``None`` when Pillow cannot
      identify the payload.
    """
    try:
        return Image.open(io.BytesIO(raw))
    except (UnidentifiedImageError, OSError):
        return None


def extract_capture_date(raw: bytes) -> DateValue | None:
    """Extract a capture date from image metadata when available.

    Checks EXIF ``DateTimeOriginal`` first, then digitized / image datetime
    fallbacks, then common textual metadata keys used by PNG/XMP-producing
    tools. The function intentionally returns only a date because
    ``progress_photos.log_date`` is date-scoped.

    **Inputs:**
    - raw (bytes): Image bytes.

    **Outputs:**
    - DateValue | None: Capture date when metadata contains one, else ``None``.
    """
    image = _open_image(raw)
    if image is None:
        return None
    with image:
        exif = image.getexif()
        for tag in _EXIF_CAPTURE_DATE_TAGS:
            parsed = _date_from_text(exif.get(tag))
            if parsed is not None:
                return parsed
        for key in _INFO_DATE_KEYS:
            parsed = _date_from_text(image.info.get(key))
            if parsed is not None:
                return parsed
    return None


def resolve_capture_date(
    *,
    raw: bytes,
    provided_date: str | None,
    default_date: str | None,
    filename: str | None,
) -> CaptureDateResolution:
    """Resolve the date to file one upload under.

    Image metadata has priority. The per-photo ``capture_date`` field is the
    next fallback, followed by the batch ``default_date``. If none are present,
    the photo is rejected rather than guessing a day.

    **Inputs:**
    - raw (bytes): Image bytes.
    - provided_date (str | None): Per-photo fallback date in ``YYYY-MM-DD``.
    - default_date (str | None): Batch fallback date in ``YYYY-MM-DD``.
    - filename (str | None): Filename used only in error text.

    **Outputs:**
    - CaptureDateResolution: Resolved date and source.

    **Exceptions:**
    - ToolError: Raised when fallback dates are malformed or no date can be
      resolved.
    """
    metadata_date = extract_capture_date(raw)
    if metadata_date is not None:
        return CaptureDateResolution(metadata_date, "metadata")
    if provided_date is not None:
        return CaptureDateResolution(parse_iso_date(provided_date), "provided")
    if default_date is not None:
        return CaptureDateResolution(parse_iso_date(default_date), "default")
    raise ToolError(
        f"{_filename_label(filename)} is missing capture date metadata; "
        "pass capture_date for that photo or default_date for the batch"
    )


def extract_image_metadata_text(raw: bytes) -> list[str]:
    """Extract searchable text metadata from an image.

    **Inputs:**
    - raw (bytes): Image bytes.

    **Outputs:**
    - list[str]: Text snippets from common EXIF and image-info metadata fields.
    """
    image = _open_image(raw)
    if image is None:
        return []
    snippets: list[str] = []
    with image:
        exif = image.getexif()
        for tag in _EXIF_TEXT_TAGS:
            text = _metadata_value_to_text(exif.get(tag))
            if text:
                snippets.append(text)
        for key in _INFO_TEXT_KEYS:
            text = _metadata_value_to_text(image.info.get(key))
            if text:
                snippets.append(text)
    return snippets


def _tokens(value: str) -> list[str]:
    """Split text into lowercase alphanumeric tokens.

    **Inputs:**
    - value (str): Text to tokenize.

    **Outputs:**
    - list[str]: Lowercase token sequence.
    """
    return _TOKEN_RE.findall(value.lower())


def _contains_subsequence(haystack: list[str], needle: list[str]) -> bool:
    """Return whether ``needle`` appears contiguously inside ``haystack``.

    **Inputs:**
    - haystack (list[str]): Token sequence to search.
    - needle (list[str]): Token sequence to find.

    **Outputs:**
    - bool: ``True`` when the full needle appears in order without gaps.
    """
    if not needle or len(needle) > len(haystack):
        return False
    last_start = len(haystack) - len(needle)
    return any(haystack[i : i + len(needle)] == needle for i in range(last_start + 1))


def _tag_tokens(row: dict[str, Any]) -> list[str]:
    """Return the normalized token sequence for a tag row.

    **Inputs:**
    - row (dict[str, Any]): Tag row.

    **Outputs:**
    - list[str]: Tokens derived from ``normalized_name`` or ``name``.
    """
    label = str(row.get("normalized_name") or row.get("name") or "")
    return _tokens(label)


def _matches_for_signal(tags: list[dict[str, Any]], signal: str) -> list[dict[str, Any]]:
    """Return tags whose normalized name appears in a text signal.

    **Inputs:**
    - tags (list[dict[str, Any]]): Existing tag rows.
    - signal (str): Searchable text signal.

    **Outputs:**
    - list[dict[str, Any]]: Matching tag rows, reduced to the longest token
      length so ``flexed front`` beats ``front``.
    """
    signal_tokens = _tokens(signal)
    matches = [row for row in tags if _contains_subsequence(signal_tokens, _tag_tokens(row))]
    if not matches:
        return []
    longest = max(len(_tag_tokens(row)) for row in matches)
    return [row for row in matches if len(_tag_tokens(row)) == longest]


def select_progress_photo_tag(
    tags: list[dict[str, Any]],
    *,
    pose_hint: str | None,
    filename: str | None,
    metadata_text: list[str],
) -> TagResolution:
    """Select exactly one existing progress-photo tag from available text signals.

    Signals are considered in confidence order: explicit ``pose_hint``,
    filename stem, then embedded text metadata. Matching uses the current tag
    catalog's ``normalized_name`` values and chooses the longest matching tag
    phrase. If a signal matches two equally-specific tags, or no signal matches
    any tag, the photo is rejected instead of being guessed into a pose.

    **Inputs:**
    - tags (list[dict[str, Any]]): Existing tag rows for the user.
    - pose_hint (str | None): Optional caller-supplied pose text.
    - filename (str | None): Optional file name.
    - metadata_text (list[str]): Text snippets extracted from image metadata.

    **Outputs:**
    - TagResolution: Selected tag row and matching signal source.

    **Exceptions:**
    - ToolError: Raised when no tags exist, no tag matches, or a signal matches
      multiple equally-specific tags.
    """
    if not tags:
        raise ToolError("No progress-photo tags exist; create at least one tag first")
    signals: list[tuple[TagMatchSource, str]] = []
    if pose_hint and pose_hint.strip():
        signals.append(("pose_hint", pose_hint))
    if filename and filename.strip():
        signals.append(("filename", PurePath(filename).stem))
    signals.extend(("metadata", snippet) for snippet in metadata_text if snippet.strip())
    for source, signal in signals:
        matches = _matches_for_signal(tags, signal)
        if len(matches) == 1:
            return TagResolution(matches[0], source)
        if len(matches) > 1:
            names = ", ".join(str(row["name"]) for row in matches)
            raise ToolError(f"Ambiguous progress-photo tag for '{signal}': matched {names}")
    raise ToolError(
        "Could not determine progress-photo tag from pose_hint, filename, or "
        "image metadata; pass pose_hint matching an existing tag"
    )


def _tag_match_response(resolution: TagResolution) -> ProgressPhotoTagMatch:
    """Build the tag-match response fragment for an accepted upload.

    **Inputs:**
    - resolution (TagResolution): Selected tag and source.

    **Outputs:**
    - ProgressPhotoTagMatch: Tool response fragment.
    """
    tag = resolution.tag
    return ProgressPhotoTagMatch(
        id=tag["id"],
        name=tag["name"],
        normalized_name=tag["normalized_name"],
        source=resolution.source,
    )


def _parse_idempotency_key(value: str | None) -> UUID | None:
    """Parse an optional idempotency key from a tool argument.

    **Inputs:**
    - value (str | None): UUID string, or ``None``.

    **Outputs:**
    - UUID | None: Parsed UUID, or ``None``.

    **Exceptions:**
    - ToolError: Raised when ``value`` is not a UUID.
    """
    if value is None:
        return None
    try:
        return UUID(value)
    except ValueError as exc:
        raise ToolError("idempotency_key must be a UUID") from exc


def _http_error_reason(exc: HTTPException) -> str:
    """Return a compact reason string from a FastAPI ``HTTPException``.

    **Inputs:**
    - exc (HTTPException): Exception raised by the canonical upload service.

    **Outputs:**
    - str: Detail text safe to include in a per-photo rejection.
    """
    detail = exc.detail
    return str(detail) if detail is not None else f"HTTP {exc.status_code}"


async def _upload_progress_photo_sources(
    *,
    sources: Sequence[SourceT],
    default_date: str | None,
    user_key: str,
    load_raw: RawLoader[SourceT],
    get_filename: FilenameGetter[SourceT],
    get_idempotency_key: IdempotencyGetter[SourceT],
) -> ProgressPhotoBulkUploadResponse:
    """Resolve and persist heterogeneous progress-photo upload sources.

    The byte loader is the only transport-specific operation. Date extraction,
    tag selection, validation, persistence, and per-item rejection behavior are
    shared by both the legacy base64 and ChatGPT file-parameter tools.

    **Inputs:**
    - sources (Sequence[SourceT]): Base64 or ChatGPT file upload items.
    - default_date (str | None): Batch capture-date fallback.
    - user_key (str): Owning user's tenant key.
    - load_raw (RawLoader[SourceT]): Async callback returning image bytes.
    - get_filename (FilenameGetter[SourceT]): Callback returning a display filename.
    - get_idempotency_key (IdempotencyGetter[SourceT]): Callback returning a UUID string.

    **Outputs:**
    - ProgressPhotoBulkUploadResponse: Accepted and rejected item summaries.
    """
    store = get_photo_store()
    accepted: list[ProgressPhotoUploadAccepted] = []
    rejected: list[ProgressPhotoUploadRejected] = []
    async with get_session() as session:
        photo_repo = ProgressPhotoRepository(session)
        tag_repo = ProgressPhotoTagRepository(session)
        async with transaction(session):
            tags = await list_tags(repo=tag_repo, user_key=user_key)

        for index, source in enumerate(sources):
            filename = get_filename(source)
            try:
                raw = await load_raw(source)
                capture_date = resolve_capture_date(
                    raw=raw,
                    provided_date=source.capture_date,
                    default_date=default_date,
                    filename=filename,
                )
                tag_resolution = select_progress_photo_tag(
                    tags,
                    pose_hint=source.pose_hint,
                    filename=filename,
                    metadata_text=extract_image_metadata_text(raw),
                )
                async with transaction(session):
                    row = await insert_one(
                        repo=photo_repo,
                        tag_repo=tag_repo,
                        store=store,
                        user_key=user_key,
                        log_date=capture_date.value,
                        tag_id=tag_resolution.tag["id"],
                        raw=raw,
                        idempotency_key=_parse_idempotency_key(get_idempotency_key(source)),
                    )
            except ToolError as exc:
                rejected.append(
                    ProgressPhotoUploadRejected(
                        index=index,
                        filename=filename,
                        reason=str(exc),
                    )
                )
                continue
            except HTTPException as exc:
                rejected.append(
                    ProgressPhotoUploadRejected(
                        index=index,
                        filename=filename,
                        reason=_http_error_reason(exc),
                    )
                )
                continue

            accepted.append(
                ProgressPhotoUploadAccepted(
                    index=index,
                    filename=filename,
                    date=row["log_date"],
                    date_source=capture_date.source,
                    tag=_tag_match_response(tag_resolution),
                    photo=_row_to_photo_metadata(row),
                )
            )

    return ProgressPhotoBulkUploadResponse(
        accepted_count=len(accepted),
        rejected_count=len(rejected),
        accepted=accepted,
        rejected=rejected,
    )


def register(mcp: FastMCP, ctx: ToolContext) -> None:
    """Register progress-photo MCP tools on the FastMCP server.

    **Inputs:**
    - mcp (FastMCP): The server to attach the tool closures to.
    - ctx (ToolContext): Shared context carrying ``user_key``.

    **Outputs:**
    - None: Tools are registered as a side effect.
    """
    user_key = ctx.user_key

    @mcp.tool
    async def list_progress_photo_tags() -> ProgressPhotoTagsResponse:
        """List existing progress-photo tags available for MCP upload matching."""
        async with get_session() as session:
            tag_repo = ProgressPhotoTagRepository(session)
            async with transaction(session):
                rows = await list_tags(repo=tag_repo, user_key=user_key)
        return ProgressPhotoTagsResponse(tags=[_row_to_tag_response(row) for row in rows])

    @mcp.tool
    async def upload_progress_photos(
        photos: Annotated[list[ProgressPhotoUploadItem], Field(min_length=1, max_length=30)],
        default_date: str | None = None,
    ) -> ProgressPhotoBulkUploadResponse:
        """Bulk-upload progress photos from base64 image data.

        For each image, the server resolves the capture date from image
        metadata when possible, falling back to the per-photo ``capture_date``
        or batch ``default_date``. It selects an existing progress-photo tag
        from ``pose_hint``, filename, or embedded text metadata, then sends
        accepted photos through the same validated service used by
        ``POST /measures/photos``. Rejected photos are reported per item so a
        bad image does not block the rest of the batch.
        """

        async def load_raw(photo: ProgressPhotoUploadItem) -> bytes:
            """Decode one base64 tool item into image bytes.

            **Inputs:**
            - photo (ProgressPhotoUploadItem): Base64 upload item.

            **Outputs:**
            - bytes: Decoded image bytes.

            **Exceptions:**
            - ToolError: Raised when the base64 value is invalid.
            """
            return decode_image_base64(photo.image_base64)

        return await _upload_progress_photo_sources(
            sources=photos,
            default_date=default_date,
            user_key=user_key,
            load_raw=load_raw,
            get_filename=lambda photo: photo.filename,
            get_idempotency_key=lambda photo: photo.idempotency_key,
        )

    @mcp.tool(
        meta={"openai/fileParams": ["photos"]},
        annotations={
            "readOnlyHint": False,
            "destructiveHint": False,
            "openWorldHint": False,
        },
    )
    async def upload_progress_photo_files(
        photos: Annotated[
            list[ChatGPTProgressPhotoFile],
            Field(min_length=1, max_length=30),
        ],
        default_date: str | None = None,
    ) -> ProgressPhotoBulkUploadResponse:
        """Upload progress photos attached directly to a ChatGPT conversation.

        ChatGPT injects each attachment's temporary ``download_url`` and
        ``file_id`` through its MCP file-parameter mechanism. The server
        downloads each image under the REST byte cap, reads capture metadata,
        resolves an existing pose tag, and delegates persistence to the same
        canonical service as REST and base64 MCP uploads. A bad attachment is
        rejected without blocking later files in the batch.
        """

        async def load_raw(photo: ChatGPTProgressPhotoFile) -> bytes:
            """Download one ChatGPT file-parameter item.

            **Inputs:**
            - photo (ChatGPTProgressPhotoFile): ChatGPT attachment reference.

            **Outputs:**
            - bytes: Downloaded image bytes.

            **Exceptions:**
            - ToolError: Raised for unsafe URLs or failed/oversized downloads.
            """
            return await download_chatgpt_file(photo)

        return await _upload_progress_photo_sources(
            sources=photos,
            default_date=default_date,
            user_key=user_key,
            load_raw=load_raw,
            get_filename=lambda photo: photo.file_name,
            get_idempotency_key=lambda photo: (
                photo.idempotency_key
                or str(uuid5(NAMESPACE_URL, f"pulse-chatgpt-file:{photo.file_id}"))
            ),
        )
