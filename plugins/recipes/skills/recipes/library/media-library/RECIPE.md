# Media Library Recipe

## Purpose

Build a centralized media library system for managing audio and image assets.
The library provides upload with server-side processing, browsable/searchable
admin UI, AI-assisted metadata generation for images, and maintenance tools for
storage hygiene. It's designed as a content authoring foundation — the upstream
source that feeds curated content to client applications.

This recipe comes in two flavors:

- **Technology-agnostic** — architecture, data model, service API, and UX
  patterns that work with any framework/database combination
- **Technology-specific** — exact implementation with Elysia + Drizzle +
  Cloudflare R2 + Nuxt/shadcn-vue + Vercel AI SDK

## When to Use

- Any app that needs centralized management of audio and/or image assets
- Content management systems where non-developers upload and organize media
- Apps that serve media to clients via presigned URLs from S3-compatible storage
- When you want AI to auto-suggest metadata (title, description, tags, alt text)
  for uploaded images
- When media assets need tagging, organization, and publish/draft lifecycle

## UI Reference

See `references/prototypes/` for interactive HTML prototypes of the admin UI:

- **`browse-mockup.html`** — Master-detail browse layout with list/grid views,
  filters, detail panel, and edit dialog
- **`upload-mockup.html`** — Upload flow with drag-and-drop, AI image analysis,
  metadata form, and "AI suggested" field indicators

Open in a browser to click through the states.

## Architecture Overview

```
Admin UI                              Client Apps
(Browse, Upload, Edit)                (Mobile, Web)
      │                                    │
      │ REST API                           │ Presigned URLs
      │ (multipart upload,                 │ (time-limited
      │  CRUD, analyze)                    │  direct-to-storage)
      ▼                                    │
┌─────────────────────────────────────┐    │
│           API Server                │    │
│                                     │    │
│  ┌───────────────┐  ┌───────────┐  │    │
│  │ Media Service  │  │ AI Service│  │    │
│  │ (upload, list, │  │ (vision   │  │    │
│  │  update, etc.) │  │  analysis)│  │    │
│  └──────┬────────┘  └─────┬─────┘  │    │
│         │                 │         │    │
│         ▼                 ▼         │    │
│  ┌──────────┐   ┌──────────────┐   │    │
│  │ Database  │   │ AI Provider  │   │    │
│  │ (items,   │   │ (vision      │   │    │
│  │  tags)    │   │  model API)  │   │    │
│  └──────────┘   └──────────────┘   │    │
│         │                           │    │
│         ▼                           │    │
│  ┌────────────────┐                │    │
│  │ S3-Compatible   │◄───────────────┼────┘
│  │ Object Storage  │                │
│  │ (R2, S3, MinIO) │                │
│  └────────────────┘                │
└─────────────────────────────────────┘
```

### Core Design Decisions

1. **Generic media table with type discriminator.** A single `media_items` table
   with a `type` column (`audio`, `image`) and JSONB `metadata` for
   type-specific fields. This avoids premature schema specialization — usage
   patterns reveal what deserves dedicated columns. Clear migration path to
   normalized per-type tables if needed.

2. **API-mediated uploads (not direct-to-storage).** Client uploads to the API
   server, which validates, processes (resize/convert images, extract audio
   metadata), and writes to storage. Simpler than presigned upload URLs, allows
   server-side processing in one pass.

3. **Presigned URLs for all media access.** Storage bucket stays private. All
   access gated through the API. This is the safer default — relaxing to public
   URLs later is easy, going the other direction is hard.

4. **Flat storage keys.** `{uuid}.{ext}` for audio, `images/{uuid}.webp` for
   images. Category and metadata live in the database, not the storage path.
   Avoids coupling storage keys to mutable metadata.

5. **Checksum-based duplicate detection.** SHA-256 of file contents prevents
   duplicate uploads. Unique index on checksum (excluding soft-deleted items).

6. **Soft-delete with deferred cleanup.** Deleting marks `deleted_at` timestamp.
   Storage files retained until explicit purge. Prevents accidental data loss.

7. **AI analysis is stateless.** The analyze endpoint takes an image, returns
   metadata suggestions, stores nothing. Separation keeps the responsibility
   boundary clean and makes re-analysis safe.

## Data Model

### media_items

| Field               | Type      | Required | Notes                                        |
| ------------------- | --------- | -------- | -------------------------------------------- |
| `id`                | UUID      | Yes      | Primary key                                  |
| `type`              | text      | Yes      | `audio` or `image`, immutable after creation |
| `title`             | text      | Yes      | Required at upload                           |
| `description`       | text      | No       | Optional                                     |
| `s3_key`            | text      | Yes      | Storage key, unique, immutable               |
| `original_filename` | text      | Yes      | Preserved from upload                        |
| `file_size`         | integer   | Yes      | Bytes                                        |
| `mime_type`         | text      | Yes      | Validated against allowed types              |
| `checksum`          | text      | Yes      | SHA-256, unique among non-deleted items      |
| `metadata`          | JSONB     | No       | Type-specific fields (see below)             |
| `published`         | boolean   | Yes      | Default false                                |
| `created_at`        | timestamp | Yes      | Auto-set                                     |
| `updated_at`        | timestamp | Yes      | Auto-set                                     |
| `deleted_at`        | timestamp | No       | Soft delete marker                           |

**JSONB metadata shapes:**

```
Audio:
  duration: number|null — seconds, extracted from file

Image:
  width: number         — pixels (after processing)
  height: number        — pixels (after processing)
  thumbnailKey: string  — storage key for thumbnail
  format: string        — output format (e.g., "webp")
  altText: string?      — accessibility description
```

Audio metadata is intentionally minimal — duration is the only universally
useful field that can be auto-extracted. Application-specific metadata (e.g.,
categories, transcripts, loop-capable flags) can be added to the JSONB as needed
for your domain.

### media_tags

| Field           | Type | Required | Notes                               |
| --------------- | ---- | -------- | ----------------------------------- |
| `media_item_id` | UUID | Yes      | FK → media_items.id, cascade delete |
| `tag`           | text | Yes      | Freeform string                     |

Composite primary key on `(media_item_id, tag)`. Tags are freeform — consistent
naming is a discipline concern, not a schema constraint.

### Key Indexes

- Unique index on `checksum` WHERE `deleted_at IS NULL` (duplicate prevention)
- Primary key on `id`
- Unique on `s3_key`

## Service Layer API

The service layer exposes these operations:

| Operation             | Input                     | Output                                       | Notes                                                                |
| --------------------- | ------------------------- | -------------------------------------------- | -------------------------------------------------------------------- |
| `uploadMedia`         | File + metadata           | MediaItem                                    | Audio: validate → extract duration → hash → store → insert           |
| `uploadImage`         | File + metadata           | MediaItem                                    | Validate → resize → convert WebP → thumbnail → hash → store → insert |
| `listMedia`           | Filters, pagination, sort | Items[] + total                              | Type, search, tags (OR), published filters                           |
| `getMediaById`        | ID                        | MediaItem \| null                            | Includes tags                                                        |
| `updateMedia`         | ID + partial metadata     | MediaItem                                    | Type-aware JSONB merge, tag replacement                              |
| `softDeleteMedia`     | ID                        | success                                      | Sets deleted_at, retains storage files                               |
| `getPresignedUrl`     | ID + variant?             | URL string                                   | Variant is specifically `'thumb'` for thumbnails                     |
| `getMediaImageBuffer` | ID                        | Buffer + contentType                         | Fetches from storage, validates type=image                           |
| `getAllTags`          | —                         | string[]                                     | Distinct tags from non-deleted items, sorted                         |
| `analyzeImage`        | Image buffer + MIME type  | Analysis result                              | Stateless — no storage, no DB writes                                 |
| `purgeDeleted`        | —                         | Count + errors                               | Hard-delete soft-deleted items + thumbnails from DB + storage        |
| `findOrphanedKeys`    | —                         | { orphanedKeys[], totalR2Keys, totalDbKeys } | Keys in storage with no DB record                                    |
| `purgeOrphanedKeys`   | —                         | Count + errors                               | Delete orphaned storage objects                                      |

## Choosing Your Implementation Path

### Technology-Agnostic

See **[references/technology-agnostic.md](references/technology-agnostic.md)**
for framework-independent architecture, implementation phases, and adaptation
guidance.

Best when:

- You're using a different tech stack (Hono, Express, Prisma, Next.js, etc.)
- You want to understand the patterns before choosing technologies
- You're adapting this to a non-TypeScript environment

### Technology-Specific (Elysia + Drizzle + R2 + Nuxt)

See **[references/elysia-drizzle-nuxt.md](references/elysia-drizzle-nuxt.md)**
for exact implementation details with this stack.

Best when:

- You're already using Elysia + Drizzle + Nuxt (or adopting them)
- You want copy-paste-ready code examples
- You need the specific integration glue between these libraries

## Gotchas & Important Notes

- **Images should be converted to WebP on upload.** Don't store the original
  format — process to a consistent format with quality control. This keeps
  storage predictable and thumbnails uniform.

- **Checksum on processed buffer, not original.** For images, compute SHA-256 on
  the processed WebP buffer (what's actually stored), not the original upload.
  Otherwise re-uploading the same image in a different format bypasses duplicate
  detection.

- **S3-first, then DB.** Upload to storage first, then insert the database
  record. If the DB insert fails, delete the storage object. The reverse (DB
  first, then storage) leaves orphaned DB records pointing to nothing.

- **AI analysis is optional, not a dependency.** The upload flow must work
  perfectly without AI analysis. Analysis is an enhancement that populates form
  fields — it should never block or gate the upload.

- **Client-side image optimization before AI analysis.** Resize to ~1024px max
  before sending to the vision API. Large images waste tokens and don't improve
  analysis quality.

- **Server-side analysis for existing images.** When analyzing images already in
  storage, fetch from storage on the server side rather than sending from the
  client. This avoids CORS issues and doesn't require the client to download the
  full-resolution image.

- **"AI suggested" indicators clear on user edit.** When AI populates a form
  field, mark it visually. When the user modifies that field, clear the
  indicator. This tells the user which values they've reviewed vs. which are raw
  AI output.

- **Soft-deleted items retain storage files indefinitely.** Don't auto-purge.
  Provide explicit admin tools for purging deleted items and orphaned storage
  objects.

- **Audio duration extraction can fail.** Some files have missing or corrupted
  metadata. Allow upload with null duration rather than rejecting the file.

- **Stored `fileSize` and `mimeType` reflect the processed file, not the
  original upload.** For images, `fileSize` is the WebP buffer length and
  `mimeType` is always `image/webp`, regardless of what was uploaded (JPEG,
  PNG). This is correct — it matches what's in storage — but can surprise
  implementers who expect the original upload metadata.

- **Purge deleted must also delete thumbnail keys.** When purging soft-deleted
  image items, delete both `s3_key` and `metadata.thumbnailKey` from storage.
  Missing the thumbnail leaves orphaned storage objects.

- **Tags UI differs between upload and edit flows.** Upload uses a
  comma-separated text input (simpler for bulk entry). Edit uses individual tag
  addition with Enter key / button and per-tag removal with X buttons. These are
  deliberately different UX patterns for different contexts.

- **Image preview URLs need explicit lifecycle management.** Use
  `URL.createObjectURL()` for local file previews and `URL.revokeObjectURL()` on
  file change and component unmount to prevent memory leaks.

- **Upload button should be disabled during AI analysis.** The `canUpload` guard
  should return `false` while `isAnalyzing` is true, preventing upload of
  incomplete AI-populated metadata.

- **R2 SDK v3.729.0+ needs `requestChecksumCalculation: 'WHEN_REQUIRED'`.**
  Without this flag, uploads fail with checksum mismatch errors on Cloudflare
  R2.
