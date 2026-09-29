# Media Library — Elysia + Drizzle + R2 + Nuxt Implementation

Exact implementation guide for building the media library with this technology
stack. Assumes an existing monorepo with an Elysia API server and a Nuxt admin
app.

## Technology Stack

| Layer            | Technology                      | Version |
| ---------------- | ------------------------------- | ------- |
| Runtime          | Bun                             | 1.x     |
| API Framework    | Elysia                          | 1.x     |
| ORM              | Drizzle ORM                     | 0.38+   |
| Database         | PostgreSQL                      | 15+     |
| Object Storage   | Cloudflare R2 (via @aws-sdk)    | SDK v3  |
| Image Processing | sharp                           | 0.33+   |
| Audio Metadata   | music-metadata                  | 7.x     |
| AI SDK           | Vercel AI SDK + OpenRouter      | ai 4.x  |
| Admin UI         | Nuxt 4 + Vue 3                  | 4.x     |
| UI Components    | shadcn-vue (Reka UI primitives) | latest  |
| Type-Safe Client | Eden Treaty                     | latest  |
| Validation       | Zod                             | 3.x     |

## Implementation Phases

### Phase 1: R2 Storage Client

Create `apps/api/src/core/storage/r2.ts`:

```typescript
import {
  S3Client,
  PutObjectCommand,
  DeleteObjectCommand,
  GetObjectCommand,
  ListObjectsV2Command,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

// Lazy singleton — avoids connection during import
let _client: S3Client | null = null;

function getClient(): S3Client {
  if (!_client) {
    _client = new S3Client({
      region: "auto",
      endpoint: env.R2_ENDPOINT,
      credentials: {
        accessKeyId: env.R2_ACCESS_KEY_ID,
        secretAccessKey: env.R2_SECRET_ACCESS_KEY,
      },
      // CRITICAL: Required for R2 compatibility with AWS SDK v3.729.0+
      requestChecksumCalculation: "WHEN_REQUIRED",
    });
  }
  return _client;
}
```

**R2-specific gotcha:** Without `requestChecksumCalculation: 'WHEN_REQUIRED'`,
uploads fail with checksum mismatch errors. This is a Cloudflare R2
compatibility issue with newer AWS SDK versions.

Export functions: `uploadToR2`, `deleteFromR2`, `getObjectFromR2`,
`getPresignedUrl`, `listR2Keys`.

**Environment variables needed:**

```
R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_BUCKET_NAME=media
```

### Phase 2: Drizzle Schema

Create `apps/api/src/features/media/db.ts`:

```typescript
import {
  pgTable,
  text,
  integer,
  boolean,
  timestamp,
  jsonb,
  primaryKey,
  uniqueIndex,
} from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";

export const mediaItems = pgTable(
  "media_items",
  {
    id: text("id")
      .primaryKey()
      .$defaultFn(() => crypto.randomUUID()),
    type: text("type").notNull(),
    title: text("title").notNull(),
    description: text("description"),
    s3Key: text("s3_key").notNull().unique(),
    originalFilename: text("original_filename").notNull(),
    fileSize: integer("file_size").notNull(),
    mimeType: text("mime_type").notNull(),
    checksum: text("checksum").notNull(),
    metadata: jsonb("metadata"),
    published: boolean("published").notNull().default(false),
    createdAt: timestamp("created_at").notNull().defaultNow(),
    updatedAt: timestamp("updated_at").notNull().defaultNow(),
    deletedAt: timestamp("deleted_at"),
  },
  (table) => ({
    checksumUniqueIdx: uniqueIndex("media_items_checksum_unique")
      .on(table.checksum)
      .where(sql`${table.deletedAt} IS NULL`),
  })
);

export const mediaTags = pgTable(
  "media_tags",
  {
    mediaItemId: text("media_item_id")
      .notNull()
      .references(() => mediaItems.id, { onDelete: "cascade" }),
    tag: text("tag").notNull(),
  },
  (table) => [primaryKey({ columns: [table.mediaItemId, table.tag] })]
);
```

**Key Drizzle patterns:**

- `$defaultFn(() => crypto.randomUUID())` for client-side UUID generation
- Partial unique index via `.where(sql\`...\`)` for checksum uniqueness
- JSONB column uses `jsonb('metadata')` — Drizzle doesn't validate JSONB
  contents, so use Zod at the application layer

Run `drizzle-kit generate` and `drizzle-kit migrate` to apply.

### Phase 3: Zod Type Definitions

Create `apps/api/src/features/media/types.ts`:

```typescript
import { z } from "zod";

// Audio metadata — just duration (auto-extracted)
export const audioMetadataSchema = z.object({
  duration: z.number().nullable().optional(),
});

export const imageMetadataSchema = z.object({
  width: z.number().int().positive(),
  height: z.number().int().positive(),
  thumbnailKey: z.string(),
  format: z.enum(["jpeg", "png", "webp"]),
  altText: z.string().optional(),
});

// Upload request schemas
export const uploadMetadataSchema = z.object({
  title: z.string().min(1).max(255),
  description: z.string().max(2000).optional(),
  tags: z.array(z.string().min(1).max(50)).max(20).optional(),
  published: z.boolean().optional(),
});

// List query schema — z.coerce for query string parsing
export const listMediaQuerySchema = z.object({
  type: z.enum(["audio", "image"]).optional(),
  search: z.string().optional(),
  tags: z.string().optional(), // comma-separated tag names (OR filter)
  published: z.enum(["true", "false"]).optional(),
  limit: z.coerce.number().min(1).max(100).default(50),
  offset: z.coerce.number().min(0).default(0),
  sort: z.enum(["created_at", "title", "file_size"]).default("created_at"),
  order: z.enum(["asc", "desc"]).default("desc"),
});

// Constants
export const ALLOWED_AUDIO_MIMES = [
  "audio/mpeg",
  "audio/mp4",
  "audio/x-m4a",
  "audio/aac",
  "audio/wav",
  "audio/x-wav",
  "audio/ogg",
  "audio/vorbis",
] as const;
export const MAX_FILE_SIZE = 50 * 1024 * 1024;
export const ALLOWED_IMAGE_MIMES = [
  "image/jpeg",
  "image/png",
  "image/webp",
] as const;
export const MAX_IMAGE_SIZE = 10 * 1024 * 1024;
export const IMAGE_MAX_DIMENSION = 2048;
export const IMAGE_WEBP_QUALITY = 90;
export const THUMBNAIL_WIDTH = 400;
export const THUMBNAIL_WEBP_QUALITY = 80;
```

**Why `z.coerce.number()` for query params:** Elysia parses query strings as
strings. `z.coerce` converts `"50"` → `50` during validation.

### Phase 4: Media Service

Create `apps/api/src/features/media/service.ts`.

**Audio upload flow — key integration points:**

```typescript
import { createHash } from "node:crypto";
import { parseBuffer } from "music-metadata";
import sharp from "sharp";

export async function uploadMedia(file: File, meta: UploadMetadata) {
  // Validate MIME type and file size
  // ...

  const buffer = Buffer.from(await file.arrayBuffer());
  const checksum = createHash("sha256").update(buffer).digest("hex");

  // Duplicate check (non-deleted items only)
  const [existing] = await db
    .select({ id: mediaItems.id, title: mediaItems.title })
    .from(mediaItems)
    .where(and(eq(mediaItems.checksum, checksum), isNull(mediaItems.deletedAt)))
    .limit(1);
  if (existing) {
    throw APIError.alreadyExists(
      `Duplicate file. Matches "${existing.title}" (${existing.id})`
    );
  }

  // Extract duration — music-metadata works in Bun
  let duration: number | null = null;
  try {
    const metadata = await parseBuffer(buffer, { mimeType: file.type });
    duration = metadata.format.duration ?? null;
  } catch {
    duration = null;
  }

  // S3-first: upload, then DB insert
  const s3Key = `${id}.${ext}`;
  await uploadToR2(s3Key, buffer, file.type);

  try {
    await db.transaction(async (tx) => {
      await tx.insert(mediaItems).values({
        /* ... */
      });
      if (meta.tags?.length) {
        const uniqueTags = [...new Set(meta.tags)];
        await tx
          .insert(mediaTags)
          .values(uniqueTags.map((tag) => ({ mediaItemId: id, tag })));
      }
    });
  } catch (err) {
    await deleteFromR2(s3Key).catch(() => {}); // Best-effort cleanup
    throw err;
  }
}
```

**Image upload — sharp processing pipeline:**

```typescript
export async function uploadImage(file: File, meta: UploadImageMetadata) {
  const buffer = Buffer.from(await file.arrayBuffer());

  // Resize + convert to WebP in one pipeline
  const { data: webpBuffer, info } = await sharp(buffer)
    .resize({
      width: IMAGE_MAX_DIMENSION,
      height: IMAGE_MAX_DIMENSION,
      fit: "inside",
      withoutEnlargement: true,
    })
    .webp({ quality: IMAGE_WEBP_QUALITY })
    .toBuffer({ resolveWithObject: true });

  // Checksum on processed buffer (what's actually stored)
  const checksum = createHash("sha256").update(webpBuffer).digest("hex");

  // Generate thumbnail from processed buffer
  const thumbnail = await sharp(webpBuffer)
    .resize({ width: THUMBNAIL_WIDTH, withoutEnlargement: true })
    .webp({ quality: THUMBNAIL_WEBP_QUALITY })
    .toBuffer();

  // Upload both in parallel
  const s3Key = `images/${id}.webp`;
  const thumbnailKey = `images/${id}-thumb.webp`;
  await Promise.all([
    uploadToR2(s3Key, webpBuffer, "image/webp"),
    uploadToR2(thumbnailKey, thumbnail, "image/webp"),
  ]);

  // DB insert with cleanup on failure...
}
```

**List with filters — Drizzle query builder:**

```typescript
export async function listMedia(query: ListMediaQuery) {
  const conditions = [isNull(mediaItems.deletedAt)];

  if (query.type) conditions.push(eq(mediaItems.type, query.type));
  if (query.search) {
    const pattern = `%${escapeLike(query.search)}%`;
    conditions.push(
      or(
        ilike(mediaItems.title, pattern),
        ilike(mediaItems.description, pattern)
      )!
    );
  }
  if (query.tags) {
    // Tags are comma-separated in the query string, split and filter
    const tagList = query.tags
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean);
    if (tagList.length > 0) {
      // OR logic: items matching ANY of the selected tags
      conditions.push(
        sql`${mediaItems.id} IN (
          SELECT ${mediaTags.mediaItemId} FROM ${mediaTags}
          WHERE ${mediaTags.tag} IN ${tagList}
        )`
      );
    }
  }

  // Run items + count in parallel
  const [items, [{ count }]] = await Promise.all([
    db
      .select()
      .from(mediaItems)
      .where(and(...conditions))
      .orderBy(orderFn(sortColumn))
      .limit(query.limit)
      .offset(query.offset),
    db
      .select({ count: sql<number>`count(*)::int` })
      .from(mediaItems)
      .where(and(...conditions)),
  ]);

  // Batch-load tags for returned items
  const tags = await db
    .select()
    .from(mediaTags)
    .where(
      inArray(
        mediaTags.mediaItemId,
        items.map((i) => i.id)
      )
    );

  const tagMap = new Map<string, string[]>();
  for (const t of tags) {
    (
      tagMap.get(t.mediaItemId) ??
      tagMap.set(t.mediaItemId, []).get(t.mediaItemId)!
    ).push(t.tag);
  }

  return {
    items: items.map((item) => ({ ...item, tags: tagMap.get(item.id) ?? [] })),
    total: count,
  };
}
```

**Drizzle gotcha — JSONB querying:** Use `sql` template literals for JSONB field
access (e.g., `metadata->>'duration'`). Drizzle doesn't have built-in JSONB
operators.

**Update with type-aware JSONB merge:**

For image items, only `altText` is mutable in metadata (dimensions and thumbnail
are immutable). Audio metadata (duration) is auto-extracted and not
user-editable.

When tags are provided, delete all existing tags and insert new ones within a
transaction.

### Phase 5: AI Image Analysis

Create `apps/api/src/features/media/analyze.ts`:

```typescript
import { generateText, Output } from "ai";
import sharp from "sharp";
import { openrouter } from "@core/ai";

const ANALYZE_MAX_DIMENSION = 1024;

export const imageAnalysisSchema = z.object({
  title: z.string().describe("Concise title (3-10 words)"),
  description: z.string().describe("Detailed description (1-3 sentences)"),
  altText: z.string().describe("Alt text for screen readers (1 sentence)"),
  tags: z.array(z.string()).min(1).max(8).describe("Relevant tags"),
});

export async function analyzeImage(
  imageBuffer: Buffer,
  mimeType: string
): Promise<ImageAnalysis> {
  // Optimize for analysis (resize if needed)
  const { buffer, mimeType: optimizedType } = await optimizeForAnalysis(
    imageBuffer,
    mimeType
  );

  // Get model from runtime configuration (not hardcoded)
  const modelId = await getModelForCategory("vision");

  const { output } = await generateText({
    model: openrouter(modelId),
    output: Output.object({ schema: imageAnalysisSchema }),
    messages: [
      {
        role: "user",
        content: [
          { type: "image", image: buffer, mediaType: optimizedType },
          {
            type: "text",
            text:
              "Analyze this image and provide metadata for a media library. " +
              "Provide a concise title, detailed description, alt text, and tags.",
          },
        ],
      },
    ],
  });

  if (!output) throw new Error("AI analysis returned no output");
  return output;
}
```

**Vercel AI SDK pattern:** Use `Output.object({ schema })` for structured output
with Zod validation. The SDK handles JSON extraction from the model response.

**Model selection:** Use a configurable category lookup (e.g., "vision") rather
than hardcoding a model ID. This lets admins swap models from a settings UI.

### Phase 6: Elysia Routes

Create `apps/api/src/routes/admin/media.ts`:

```typescript
import { Elysia, t } from "elysia";

export const mediaRoutes = new Elysia({ prefix: "/admin/media" })
  // List with query params
  .get("/", async ({ query }) => {
    const parsed = listMediaQuerySchema.parse(query);
    return listMedia(parsed);
  })

  // Get unique tags (returns { tags: string[] } envelope)
  .get("/tags", async () => {
    const tags = await getAllTags();
    return { tags };
  })

  // Get single item
  .get("/:id", async ({ params }) => {
    const item = await getMediaById(params.id);
    if (!item) throw new APIError(404, "Not found");
    return item;
  })

  // Presigned URL (supports ?variant=thumb)
  .get("/:id/url", async ({ params, query }) => {
    const url = await getMediaPresignedUrl(params.id, query.variant);
    return { url };
  })

  // Audio upload (multipart)
  .post(
    "/upload",
    async ({ body }) => {
      const file = body.file;
      const tags = body.tags ? JSON.parse(body.tags) : undefined;
      const meta = uploadMetadataSchema.parse({
        title: body.title,
        description: body.description,
        tags,
        published: body.published === "true",
      });
      return uploadMedia(file, meta);
    },
    {
      body: t.Object({
        file: t.File(),
        title: t.String(),
        description: t.Optional(t.String()),
        tags: t.Optional(t.String()), // JSON string of string[]
        published: t.Optional(t.String()),
      }),
    }
  )

  // Image upload
  .post("/upload-image", async ({ body }) => {
    // Similar to audio but uses uploadImage service
  })

  // Analyze image before upload (stateless)
  .post("/analyze-image", async ({ body }) => {
    const buffer = Buffer.from(await body.file.arrayBuffer());
    return analyzeImage(buffer, body.file.type);
  })

  // Analyze existing image (server fetches from R2)
  .post("/:id/analyze", async ({ params }) => {
    const { buffer, contentType } = await getMediaImageBuffer(params.id);
    return analyzeImage(buffer, contentType);
  })

  // Update metadata
  .patch("/:id", async ({ params, body }) => {
    const parsed = updateMediaSchema.parse(body);
    return updateMedia(params.id, parsed);
  })

  // Soft delete
  .delete("/:id", async ({ params }) => {
    return softDeleteMedia(params.id);
  })

  // Purge operations
  .post("/purge/deleted", () => purgeDeletedMedia())
  .get("/purge/orphans", () => findOrphanedR2Keys())
  .post("/purge/orphans", () => purgeOrphanedR2Keys());
```

**Elysia multipart handling:** Use `t.File()` in the body schema for multipart
file uploads. Elysia handles parsing automatically. String fields in multipart
forms are always strings — parse booleans and JSON manually.

**Elysia gotcha — tags as JSON string:** Multipart forms can't send arrays
natively. Send tags as a JSON string (`JSON.stringify(tags)`) and parse
server-side.

### Phase 7: Nuxt Admin — API Helpers

Create type-safe API wrappers using Eden Treaty:

```typescript
// apps/admin/app/lib/api-helpers.ts
import { useApi } from "~/lib/api";

export async function fetchMediaList(params: Record<string, string | number>) {
  const api = useApi();
  const { data, error } = await api.api.admin.media.get({ query: params });
  if (error) throw new Error("Failed to fetch media");
  return data;
}

export async function analyzeMediaImage(file: File) {
  const formData = new FormData();
  formData.append("file", file);
  const response = await fetch("/api/admin/media/analyze-image", {
    method: "POST",
    body: formData,
    credentials: "include",
  });
  if (!response.ok) throw new Error("Analysis failed");
  return response.json();
}

// analyzeMediaItemImage uses server-side R2 fetch (bypasses CORS)
export async function analyzeMediaItemImage(id: string) {
  const api = useApi();
  const { data, error } = await api.api.admin.media({ id }).analyze.post();
  if (error) throw new Error("Analysis failed");
  return data;
}
```

**Eden Treaty gotcha — multipart uploads:** Eden Treaty doesn't handle
multipart/FormData well for file upload endpoints (`/upload`, `/upload-image`).
Use raw `fetch()` for those. However, Eden Treaty **does** work for the
`/analyze-image` endpoint (simpler single-file body). Use Eden Treaty for
analyze, CRUD, and all non-upload endpoints.

### Phase 8: Nuxt Admin — useImageAnalysis Composable

This composable encapsulates AI analysis state management, reusable across
upload and edit flows:

```typescript
// apps/admin/app/composables/useImageAnalysis.ts
export function useImageAnalysis(
  onResult: (result: ImageAnalysis) => Promise<void>
) {
  const isAnalyzing = ref(false);
  const analyzeError = ref("");
  const aiSuggested = ref<Record<string, boolean>>({
    title: false,
    description: false,
    altText: false,
    tags: false,
  });

  let skipAiClear = false; // Prevents watchers from clearing indicators

  function watchField(source: WatchSource, field: string, options?: object) {
    watch(
      source,
      () => {
        if (!skipAiClear) aiSuggested.value[field] = false;
      },
      options
    );
  }

  async function analyzeFile(file: File) {
    isAnalyzing.value = true;
    try {
      const optimized = await prepareImageForAnalysis(file);
      const result = await analyzeMediaImage(optimized);
      skipAiClear = true;
      await onResult(result);
      await nextTick(); // Let watchers fire with skipAiClear=true
      skipAiClear = false;
      // Set all fields as AI-suggested with a typed object literal
      // (not Object.keys iteration — catches missing keys at compile time)
      aiSuggested.value = {
        title: true,
        description: true,
        altText: true,
        tags: true,
      };
    } catch (err) {
      analyzeError.value = err instanceof Error ? err.message : "Failed";
    } finally {
      isAnalyzing.value = false;
    }
  }

  function aiFieldClass(field: string): string {
    return aiSuggested.value[field]
      ? "border-violet-300 bg-violet-50 dark:border-violet-700 dark:bg-violet-950"
      : "";
  }

  // Return reactive refs as readonly to prevent external mutation
  return {
    isAnalyzing: readonly(isAnalyzing),
    analyzeError: readonly(analyzeError),
    aiSuggested: readonly(aiSuggested),
    hasAnySuggestion: computed(() =>
      Object.values(aiSuggested.value).some(Boolean)
    ),
    watchField,
    analyzeFile, // For upload flow (client-side optimization)
    analyzeById, // For edit flow (server fetches from R2, no CORS)
    resetAnalysis,
    aiFieldClass,
  };
}
```

**Critical pattern — `skipAiClear`:** When `onResult` sets form field values,
Vue's reactivity triggers the field watchers. Without the `skipAiClear` flag,
those watchers immediately clear the AI indicators. The sequence is:

1. Set `skipAiClear = true`
2. Call `onResult(result)` — sets field values
3. `await nextTick()` — lets watchers fire (they check skipAiClear and no-op)
4. Set `skipAiClear = false`
5. Set all `aiSuggested` fields to `true`

### Phase 9: Client-Side Image Optimization

Optimize images before sending to the AI analysis endpoint:

```typescript
// apps/admin/app/lib/image-utils.ts
export async function prepareImageForAnalysis(file: File): Promise<File> {
  const bitmap = await createImageBitmap(file);
  const maxDim = 1024;

  if (bitmap.width <= maxDim && bitmap.height <= maxDim) return file;

  const scale = Math.min(maxDim / bitmap.width, maxDim / bitmap.height);
  const w = Math.round(bitmap.width * scale);
  const h = Math.round(bitmap.height * scale);

  // Use document.createElement('canvas'), NOT OffscreenCanvas
  // OffscreenCanvas has different browser compatibility and this runs
  // in the main thread of the Nuxt admin, not a Web Worker
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d")!;
  ctx.drawImage(bitmap, 0, 0, w, h);

  // canvas.toBlob is callback-based, wrap in a Promise
  const blob = await new Promise<Blob>((resolve) => {
    canvas.toBlob((b) => resolve(b!), "image/webp", 0.9);
  });

  // Rename file extension to .webp to match the converted format
  return new File([blob], file.name.replace(/\.[^.]+$/, ".webp"), {
    type: "image/webp",
  });
}
```

Uses browser APIs (`createImageBitmap`, `canvas.toBlob`) — no dependencies.

**Gotcha — NOT `OffscreenCanvas`:** While `OffscreenCanvas` has a cleaner
Promise-based API (`convertToBlob`), it has different browser compatibility.
Since this runs in the main thread of a Nuxt admin SPA (not a Web Worker), use
the standard `document.createElement('canvas')` API.

### Phase 10: Nuxt Admin Pages and Components

> **Prototype available:** See `references/prototypes/browse-mockup.html` and
> `references/prototypes/upload-mockup.html` for interactive visual references.

**Directory structure:**

```
apps/admin/app/
├── pages/admin/media/
│   ├── index.vue           — Browse page (master-detail)
│   └── upload.vue          — Upload page
├── components/media/
│   ├── MediaDetailPanel.vue — Detail sidebar
│   ├── MediaEditDialog.vue  — Edit modal with AI analyze
│   ├── MediaGridView.vue    — Grid layout cards
│   └── ImagePickerDialog.vue — Reusable image selector
├── composables/
│   └── useImageAnalysis.ts  — AI analysis state (Phase 8)
└── lib/
    ├── api-helpers.ts       — Type-safe API wrappers
    ├── types.ts             — Frontend type definitions
    └── image-utils.ts       — Client-side image optimization
```

**`ImagePickerDialog` — reusable image selector for other features:**

This component is a modal dialog used by other admin features (e.g., experience
editor, collection editor) to select a published image from the media library.
It shows only published images, has debounced search, loads thumbnails inline,
and returns either an image ID or null. Build this alongside the media library
so other features can reference media items immediately.

**shadcn-vue components used:**

- Layout: `Card`, `Table`, `Badge`, `Separator`, `Dialog`, `AlertDialog`
- Forms: `Input`, `Textarea`, `Select`, `Switch`, `Label`, `Button`
- Navigation: `ToggleGroup`, `DropdownMenu`
- Icons: `lucide-vue-next` (FileAudio, ImageIcon, Upload, Search, Sparkles,
  Loader2, Pencil, Trash2, X, Plus, etc.)

**shadcn-vue gotcha — Reka UI v2 binding:** Use `v-model` for all form
components (Switch, Checkbox, etc.). Do NOT use `:checked` / `@update:checked` —
that's the old Radix Vue API and silently fails.

**Key UI patterns:**

- **Thumbnail loading:** When the list loads, batch-fetch presigned thumbnail
  URLs for all image items. Store in a `Record<string, string>` reactive map.
  Share the map between list and grid views.

- **Auto-switch upload type:** When a user drops an image file while in audio
  mode, auto-switch `uploadType` to 'image'. Use a `skipNextClear` flag to
  prevent the type-change watcher from clearing the staged file.

- **Debounced search:** Use `useDebounceFn` from VueUse (300ms) for the search
  input. Reset pagination offset to 0 on filter changes.

- **Detail panel push layout:** The detail panel is a fixed-width sidebar
  (400px) that pushes the main content. Use flex layout with `shrink-0` on the
  panel and `min-w-0` on the main content.

## Key Gotchas (Elysia + Drizzle Specific)

- **Image `fileSize` stores the processed WebP size, not the original.** Set
  `fileSize: webpBuffer.length`, not `file.size`. Similarly, `mimeType` is
  always `'image/webp'` regardless of the uploaded format.

- **Tags in multipart forms must be a JSON string.** Multipart forms can't send
  arrays natively. Client sends `JSON.stringify(tags)`, server parses with
  `JSON.parse(body.tags)`. Wrap the parse in a try/catch and throw a descriptive
  error on failure.

- **Elysia `t.File()` type filter for analyze-image.** Use
  `t.File({ type: ['image/jpeg', 'image/png', 'image/webp'] })` to reject
  non-image files at the Elysia layer (422) before reaching the handler.

- **`DialogScrollContent` for the edit dialog, not `DialogContent`.** The
  standard `DialogContent` clips overflow. Long forms with many tags need the
  scroll variant.

- **Published toggle in detail panel uses one-way binding.** The detail panel's
  published `Switch` uses `:model-value` +
  `@update:model-value="togglePublished"` (not `v-model`) because it calls an
  API and only updates state on success. This is a valid exception to the
  "always use v-model" rule.

## Integration Checklist

- [ ] R2 storage client with all CRUD operations
- [ ] Drizzle schema with migration
- [ ] Zod schemas for all request/response types
- [ ] Media service with audio + image upload, list, update, delete
- [ ] AI analysis endpoint (stateless)
- [ ] Elysia routes mounted under `/admin/media`
- [ ] Admin auth guard on all routes
- [ ] Nuxt browse page with list/grid views + detail panel
- [ ] Nuxt upload page with drag-drop + AI analysis
- [ ] useImageAnalysis composable
- [ ] Client-side image optimization
- [ ] Purge tools (deleted items + orphaned storage keys)
- [ ] Tests for service, types, and AI analysis
