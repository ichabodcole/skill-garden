# Media Library — Technology-Agnostic Implementation Guide

This guide covers architecture, data model, service patterns, and UX design for
a media library system, independent of any specific framework or database.

## Implementation Phases

Phases are ordered by dependency. Complete each before starting the next.

### Phase 1: Storage Client

Set up the S3-compatible storage client (R2, S3, MinIO, etc.).

**Operations needed:**

```
uploadToStorage(key: string, buffer: Buffer, contentType: string): void
deleteFromStorage(key: string): void
getObjectFromStorage(key: string): { buffer: Buffer, contentType: string }
getPresignedUrl(key: string, expiresIn?: number): string
listAllKeys(): string[]
```

**Key decisions:**

- Use a singleton/lazy-initialized client to avoid repeated connection setup
- Presigned URLs should default to 1-hour expiry
- The `listAllKeys` operation should handle pagination (S3 returns max 1000 keys
  per request)

**Validate:** Upload a test file, retrieve it via presigned URL, delete it.

### Phase 2: Database Schema

Create the `media_items` and `media_tags` tables as described in the main
SKILL.md data model section.

**SQL-like schema:**

```sql
CREATE TABLE media_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type          TEXT NOT NULL,               -- 'audio' | 'image'
  title         TEXT NOT NULL,
  description   TEXT,
  s3_key        TEXT NOT NULL UNIQUE,
  original_filename TEXT NOT NULL,
  file_size     INTEGER NOT NULL,            -- bytes
  mime_type     TEXT NOT NULL,
  checksum      TEXT NOT NULL,               -- SHA-256 hex
  metadata      JSONB,                       -- type-specific fields
  published     BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  deleted_at    TIMESTAMP                    -- soft delete
);

-- Duplicate prevention: unique checksum among non-deleted items
CREATE UNIQUE INDEX media_items_checksum_unique
  ON media_items (checksum)
  WHERE deleted_at IS NULL;

CREATE TABLE media_tags (
  media_item_id UUID NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  tag           TEXT NOT NULL,
  PRIMARY KEY (media_item_id, tag)
);
```

**Why JSONB for metadata:** Type-specific fields (audio duration, image
dimensions, alt text) vary by media type. JSONB keeps the schema generic while
allowing type-aware application logic. Validate JSONB shapes at the application
layer (e.g., Zod schemas keyed on `type`).

**Validate:** Run the migration, insert a test record, query it back.

### Phase 3: Audio Upload Service

Implement the audio upload flow:

```
1. Validate MIME type against allowed list
   (MP3, M4A/AAC, WAV, OGG — configurable)
2. Validate file size (e.g., 50 MB limit)
3. Read file into buffer
4. Compute SHA-256 checksum
5. Check for duplicate checksum in DB (non-deleted items only)
   → If duplicate found, reject with reference to existing item
6. Extract audio duration via metadata library
   → On failure, set duration to null (don't reject)
7. Generate UUID + S3 key ({uuid}.{ext})
8. Build JSONB metadata ({ duration })
9. Upload buffer to S3
10. Insert DB record + tags in a transaction
    → On DB failure, delete the S3 object (cleanup)
11. Return created item with tags
```

Audio metadata is intentionally minimal — just the auto-extracted duration. If
your app needs additional audio-specific fields (e.g., categories, transcripts,
loop-capable flags), add them to the JSONB metadata shape and extend validation
accordingly. Tags handle general organization.

**Validate:** Upload an audio file, verify it appears in the database with
correct metadata, retrieve it via presigned URL.

### Phase 4: Image Upload Service

Implement the image upload flow:

```
1. Validate MIME type (JPEG, PNG, WebP — configurable)
2. Validate file size (e.g., 10 MB limit)
3. Read file into buffer
4. Process with image library:
   a. Resize to max dimension (e.g., 2048px, fit: inside)
   b. Convert to WebP (quality ~90%)
   c. Extract width/height from processed buffer
5. Compute SHA-256 checksum on PROCESSED buffer
   (not original — this is what's stored)
6. Check for duplicate checksum
7. Generate thumbnail:
   a. Resize processed buffer to thumbnail width (e.g., 400px)
   b. Convert to WebP (lower quality, e.g., 80%)
8. Generate UUID + S3 keys:
   - Full: images/{uuid}.webp
   - Thumbnail: images/{uuid}-thumb.webp
9. Upload both files to S3 in parallel
10. Build JSONB metadata (width, height, thumbnailKey, format, altText)
11. Insert DB record + tags in a transaction
    → On failure, delete both S3 objects
12. Return created item with tags
```

**Why convert to WebP:** Consistent format, smaller file sizes, uniform
thumbnails. The original format doesn't matter — store what you'll serve.

**Validate:** Upload an image, verify WebP conversion, check thumbnail
generation, retrieve both variants via presigned URL.

### Phase 5: List, Read, Update, Delete

**List with filters:**

```
SELECT * FROM media_items
WHERE deleted_at IS NULL
  AND (type = :type OR :type IS NULL)
  AND (published = :published OR :published IS NULL)
  AND (title ILIKE '%search%' OR description ILIKE '%search%' OR :search IS NULL)
  AND (id IN (SELECT media_item_id FROM media_tags WHERE tag IN (:tags)) OR :tags IS NULL)
ORDER BY :sort :order
LIMIT :limit OFFSET :offset
```

Multiple tags use OR logic (`WHERE tag IN (...)`) — items matching any of the
selected tags are returned. Tags are passed as a comma-separated string in the
query parameter and split server-side.

Run the items query and a COUNT query in parallel for pagination.

After fetching items, batch-load tags for all returned item IDs (single query,
build a tag map, attach to items).

**Update (type-aware JSONB merge):**

When updating metadata, preserve existing JSONB fields and only modify what's
provided. For image items, only `altText` is updatable in metadata (dimensions
and thumbnail are immutable). Audio metadata (duration) is auto-extracted and
not user-editable.

When tags are provided in an update, replace all existing tags (delete all →
insert new) within a transaction.

**Soft delete:**

Set `deleted_at = NOW()` and `updated_at = NOW()`. Don't delete the storage
object — that happens during purge.

**Presigned URLs:**

For image items with a `thumb` variant requested, return the presigned URL for
`metadata.thumbnailKey` instead of `s3_key`.

**Validate:** List with each filter combination, update metadata, soft-delete an
item, verify it's excluded from list queries.

### Phase 6: Admin UI — Browse & Detail

> **Prototype available:** See `prototypes/browse-mockup.html` for a clickable
> reference of the browse UI described below.

**Master-detail layout:**

- **Left panel (master):** Filterable, searchable list of media items
- **Right panel (detail):** Slides in when an item is selected, shows full
  metadata and media preview

**Filters bar:**

- Type toggle: All / Audio / Images
- Search input (debounced, ILIKE on title/description)
- Published status toggle: All / Published / Draft
- Tag pills (own row below): appear when tags are selected as filters (from
  detail panel), removable individually with X, "Clear all" when 2+ tags active

**List view (default):**

Data table with columns: thumbnail/icon, title, type badge, duration/dimensions,
file size, published badge, created date. Rows are clickable to open the detail
panel.

Image items show a loaded thumbnail in the first column. Audio items show a
file-audio icon.

**Grid view (toggle):**

Cards in a responsive grid. Each card shows a thumbnail area (image preview or
audio icon), title, type badge, published badge, and compact metadata (duration
or dimensions + file size).

**Detail panel (sidebar):**

- Header: title + original filename + close button
- Action bar: Edit button, Delete button
- Media preview: audio player or image display
- File info grid: MIME type, file size, dimensions/duration, checksum
  (truncated), timestamps
- Metadata section: type badge, published toggle (inline, saves immediately),
  description, type-specific fields (alt text for images), tags (clickable —
  clicking a tag adds it as a filter in the browse bar, using OR logic across
  multiple selected tags; active tags are visually highlighted)

**Edit dialog:**

Modal/dialog with editable form fields: title, description, tags (add/remove
individual tags), type-specific fields (alt text for images), published toggle.
For image items, shows the image and an "Analyze" button (see Phase 8).

**Pagination:**

Offset-based with Previous/Next buttons. Show "Showing X-Y of Z items".

**Empty states:**

- No items at all: "No media items found. Upload your first file."
- No items match filters: "No media items match your filters."

**Validate:** Browse works with filters, selecting items opens detail panel,
editing and deleting work correctly.

### Phase 7: Admin UI — Upload

> **Prototype available:** See `prototypes/upload-mockup.html` for a clickable
> reference of the upload UI described below.

**Upload type selector:**

Toggle between Audio and Image mode. Auto-switches if a dropped file matches the
other type (e.g., drop an image file while in audio mode → switch to image
mode).

**Drop zone:**

Full-width dashed-border area. Drag-and-drop or click to browse. Shows file info
after selection (name, size, and image preview for images). Shows accepted
formats and size limits.

**Metadata form:**

- Title (pre-populated from filename without extension)
- Description (optional)
- Alt text (image only)
- Tags (comma-separated input, displayed as badges below)
- Published toggle with description text
- Upload button (disabled until required fields are filled)

**AI Analysis CTA (image only):**

When an image file is selected, show a prominent call-to-action card:

```
┌──────────────────────────────────────────────┐
│ ✦ Let AI fill in the metadata                │
│   Analyzes the image and suggests title,     │
│   description, alt text, and tags.           │
│                                 [Analyze]    │
└──────────────────────────────────────────────┘
```

This card disappears after analysis completes. See Phase 8 for the full AI
integration.

**Validate:** Upload audio and image files, verify correct processing, verify
form validation prevents incomplete uploads.

### Phase 8: AI-Assisted Image Metadata

This phase adds AI-powered metadata suggestion for image uploads. The system is
designed as a stateless analysis endpoint — it takes an image, returns
suggestions, stores nothing.

**API endpoint:** `POST /analyze-image`

- Accepts a multipart image upload
- Optimizes image for analysis (resize to ~1024px max)
- Sends to a vision model API (OpenAI, OpenRouter, etc.)
- Returns structured JSON: `{ title, description, altText, tags[] }`

**Server-side analysis of existing images:** `POST /:id/analyze`

- Server fetches the image from storage directly (avoids CORS issues)
- Optimizes and sends to vision model
- Returns the same structured JSON

**AI analysis prompt guidance:**

```
Analyze this image and provide metadata for a media library.
Provide:
- A concise title (3-10 words)
- A detailed description (1-3 sentences)
- Accessible alt text (1 sentence)
- Relevant tags (1-8 tags)
```

Add application context to the prompt (e.g., "This image will be used in [your
app's domain]") for more relevant suggestions.

**Frontend integration — Upload flow:**

1. User selects an image file
2. User clicks "Analyze" (explicit action, not automatic)
3. Client optimizes the image (resize to 1024px, convert to WebP)
4. Client sends to analyze endpoint
5. On success: populate form fields with suggestions
6. Mark populated fields as "AI suggested" (visual indicator — e.g., colored
   border/background)
7. When user edits a field, clear the AI indicator for that field
8. User reviews/edits, then clicks Upload normally

**Frontend integration — Edit flow:**

Same as upload, but uses the server-side analysis endpoint (which fetches the
image from storage directly, bypassing CORS).

**"AI suggested" field indicator pattern:**

Track which fields have AI-populated values using a per-field boolean map:

```
aiSuggested = { title: false, description: false, altText: false, tags: false }
```

When analysis succeeds, set all to `true`. When a field's value changes (via
user edit), set that field to `false`. Use the map to apply visual styling
(e.g., a violet border/background class).

**Critical:** Use a `skipAiClear` flag when programmatically setting field
values from AI results. Without this, the field watchers immediately clear the
AI indicators when the values are set.

**Model selection:**

Use a configurable model reference rather than hardcoding a model ID. This lets
administrators swap vision models without code changes.

**Validate:** Analyze an image during upload, verify suggestions populate
fields, verify indicators clear on edit, verify analysis works on existing
items.

### Phase 9: Maintenance Tools

**Purge soft-deleted items:**

1. Query all items where `deleted_at IS NOT NULL`
2. For each: delete storage object (and thumbnail for images)
3. Track failures — don't hard-delete DB records for items whose storage
   deletion failed
4. Hard-delete successfully purged items from DB
5. Return count + errors

**Find and purge orphaned storage keys:**

1. List all keys in storage bucket (paginated)
2. Query all `s3_key` values from DB (including soft-deleted items) + thumbnail
   keys from image metadata
3. Diff: keys in storage but not in DB = orphaned
4. Optionally delete orphaned keys

Both operations should be admin-only manual actions (not automated), exposed via
the admin UI settings menu with confirmation dialogs.

**Validate:** Soft-delete an item, purge it, verify storage cleanup. Upload a
file, delete its DB record manually, run orphan detection.

## Adapting to Different Tech Stacks

### Database

- **PostgreSQL + any ORM** (Drizzle, Prisma, TypeORM, Knex): Use the SQL schema
  directly. JSONB is native to PostgreSQL.
- **MySQL/MariaDB**: Use JSON column type instead of JSONB. Adjust the partial
  unique index on checksum (MySQL doesn't support WHERE clauses on indexes — use
  a generated column or application-level duplicate check).
- **SQLite**: Use JSON column type. No partial unique indexes — enforce
  duplicate checking at the application layer.
- **MongoDB**: The JSONB metadata pattern maps naturally to embedded documents.
  Tags can be an array field on the document instead of a separate collection.

### API Framework

- **Express/Hono/Fastify**: Replace route definitions. Multipart upload handling
  varies (multer for Express, built-in for Hono/Fastify).
- **Next.js API Routes**: Use Route Handlers with `request.formData()` for
  multipart uploads.
- **tRPC**: Upload doesn't fit tRPC's RPC model well. Consider a separate REST
  endpoint for upload, tRPC for everything else.

### Image Processing

- **sharp** (Node.js): The reference implementation. Fast, well-maintained,
  handles resize/convert/thumbnail.
- **Jimp** (pure JavaScript): Slower but no native dependencies. Useful if sharp
  won't install in your environment.
- **Pillow** (Python): Equivalent functionality for Python backends.
- **Server-side vs client-side**: Always process on the server for consistency.
  Client-side processing can supplement (e.g., optimizing before AI analysis)
  but shouldn't replace server-side validation and conversion.

### Storage

- **Cloudflare R2**: S3-compatible, zero egress fees. Use `@aws-sdk/client-s3`.
- **AWS S3**: Same SDK. Add region configuration.
- **MinIO**: Self-hosted S3-compatible. Same SDK, different endpoint.
- **Google Cloud Storage**: Different SDK but same concepts (presigned URLs
  become "signed URLs").
- **Azure Blob Storage**: Different SDK (SAS tokens instead of presigned URLs).

### AI Provider

- **OpenRouter**: Multi-model gateway. Good for flexibility (swap models without
  code changes).
- **OpenAI**: Direct GPT-4 Vision API.
- **Anthropic Claude**: Vision support in Claude models.
- **Local models**: LLaVA or similar via Ollama for self-hosted analysis.

### Admin UI Framework

- **Vue/Nuxt + shadcn-vue**: The reference implementation.
- **React/Next.js + shadcn/ui**: Same component patterns, different framework.
- **Svelte/SvelteKit**: Similar component architecture.
- **The UI patterns are framework-independent.** Master-detail layout, filter
  bar, upload form with AI integration — these work the same way regardless of
  component library.
