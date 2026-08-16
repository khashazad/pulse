---
name: upload-pulse-progress-photos
description: Use when a user attaches physique, body-progress, workout-progress, check-in, or transformation photos and asks to upload, log, save, organize, or backfill them in Pulse through MCP, including batches spanning multiple dates.
---

# Upload Pulse Progress Photos

File attached photos through Pulse MCP under their capture dates and existing pose tags. Treat the tool response as authoritative; never claim success before an item appears in `accepted`.

## Workflow

1. Call `list_progress_photo_tags` before the first batch unless its current result is already in the conversation.
2. In ChatGPT, call `upload_progress_photo_files`. Its `photos` argument is an OpenAI file parameter. Select the user's actual attachments and let ChatGPT inject `download_url`, `file_id`, `mime_type`, and `file_name`. Never invent, transcribe, or replace those values.
3. Preserve attachment order. Inspect each image visually and set `pose_hint` to an exact existing tag name only when the pose is clear. Never create or approximately match a tag. Ask the user to choose from the catalog when ambiguous.
4. Let Pulse read EXIF/common capture metadata by omitting both date fields.
5. Set per-photo `capture_date` only from a date the user stated in the conversation. A filename is not confirmation, even when it contains `YYYY-MM-DD`. If metadata is known to be absent, ask for the date before uploading. Use `default_date` only when the user says every photo in that call shares one date. Never use today, upload time, file timestamps, or filename dates.
6. Send at most 30 items per call. Split larger sets or client payload-limit failures into smaller ordered batches.
7. Report accepted and rejected items separately. Retry only rejected items after resolving their stated reasons. Pulse derives stable retry identity from each ChatGPT `file_id`.

If `upload_progress_photo_files` is unavailable, the Pulse connection is stale or incomplete. Ask the user to refresh or recreate the plugin connection; do not fabricate file references or fall back to base64 in ChatGPT. Only non-ChatGPT MCP clients that truly expose attachment bytes should use `upload_progress_photos`.

## File Parameter Shape

ChatGPT supplies the first four fields. The model may add only the hint/fallback fields shown below:

```json
{
  "photos": [
    {
      "download_url": "<injected by ChatGPT>",
      "file_id": "<injected by ChatGPT>",
      "mime_type": "<injected by ChatGPT when available>",
      "file_name": "<injected by ChatGPT when available>",
      "pose_hint": "flexed front",
      "capture_date": "2026-08-10"
    }
  ],
  "default_date": "2026-08-10"
}
```

Every item requires host-provided `download_url` and `file_id`. Omit unused optional fields instead of sending `null`. Normally use either per-photo `capture_date` or batch `default_date`, not both. Omit both when metadata should determine the date.

## Handle Rejections

Use returned `index` and `filename` to align results with attachments.

| Reason | Action |
|---|---|
| Missing date | Ask for that photo's date; retry it with `capture_date`. |
| Unmatched/ambiguous tag | Show existing tags and ask which applies. |
| Download failed/expired | Retry once with the same live attachment; otherwise request reattachment. |
| Invalid image | Request a supported image attachment. |
| Too large/unsupported | Relay the reason and request a supported or smaller copy. |
| Other validation error | Preserve the exact reason and request only its correction. |

Never invent fields such as `file`, `image_base64`, `taken_at`, `tag`, or `tags` for the ChatGPT file tool. Never resend accepted photos. A completion message must name accepted dates/tags, then each rejected filename and the one decision needed to retry it.
