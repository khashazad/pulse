---
name: upload-pulse-progress-photos
description: Use when a user attaches physique, body-progress, workout-progress, check-in, or transformation photos and asks to upload, log, save, organize, or backfill them in Pulse through MCP, including batches spanning multiple dates.
---

# Upload Pulse Progress Photos

File attached photos through Pulse MCP under their capture dates and existing pose tags. Treat the tool response as authoritative; never claim success before an item appears in `accepted`.

## Workflow

1. Call `list_progress_photo_tags` before the first batch unless its current result is already in the conversation.
2. Read each attachment as bytes and base64-encode those exact bytes. Use raw base64 or `data:image/<type>;base64,<payload>`. Never pass a path, URL, attachment handle, or placeholder.
3. Preserve attachment order and include `filename` when available.
4. Set `pose_hint` to an exact existing tag name only when the image or user text makes the pose clear. Never create or approximately match a tag. Ask the user to choose from the catalog when ambiguous.
5. Let Pulse read EXIF/common capture metadata by omitting both date fields.
6. Set per-photo `capture_date` only from a date the user stated in the conversation. A filename is not confirmation, even when it contains `YYYY-MM-DD`. If metadata is known to be absent, ask for the date before uploading. Use `default_date` only when the user says every photo in that call shares one date. Never use today, upload time, file timestamps, or filename dates.
7. Generate one UUID `idempotency_key` per photo and retain it for exact retries.
8. Send at most 30 items per `upload_progress_photos` call. Split larger sets or client payload-limit failures into smaller ordered batches.
9. Report accepted and rejected items separately. Retry only rejected items after resolving their stated reasons, using the same idempotency keys.

If the runtime cannot read attachment bytes or provide base64 to MCP, state that limitation and stop. Never fabricate image data.

## Exact Payload

Use only these fields:

```json
{
  "photos": [
    {
      "image_base64": "data:image/jpeg;base64,<actual attachment bytes>",
      "filename": "check-in-front.jpg",
      "pose_hint": "flexed front",
      "capture_date": "2026-08-10",
      "idempotency_key": "<stable-per-photo-key>"
    }
  ],
  "default_date": "2026-08-10"
}
```

Every item requires `image_base64`; all other fields are optional. Omit unused fields instead of sending `null`. Normally use either per-photo `capture_date` or batch `default_date`, not both. Omit both when metadata should determine the date.

## Handle Rejections

Use returned `index` and `filename` to align results with attachments.

| Reason | Action |
|---|---|
| Missing date | Ask for that photo's date; retry it with `capture_date`. |
| Unmatched/ambiguous tag | Show existing tags and ask which applies. |
| Invalid base64/image | Re-read exact bytes; request reattachment if unavailable. |
| Too large/unsupported | Relay the reason and request a supported or smaller copy. |
| Other validation error | Preserve the exact reason and request only its correction. |

Never invent fields such as `file`, `taken_at`, `tag`, or `tags`. Never resend accepted photos. A completion message must name accepted dates/tags, then each rejected filename and the one decision needed to retry it.
