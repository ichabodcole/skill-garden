---
name: screenshot-optimization
description:
  This skill should be used when the user asks to "optimize screenshots",
  "convert screenshots to WebP", "compress images for the repo", "save
  screenshots as WebP", or when capturing documentation screenshots that should
  be stored efficiently. Converts PNG screenshots to WebP format using sharp-cli
  via npx.
---

# Screenshot Optimization

Convert PNG screenshots to WebP format for efficient storage in the repository.
WebP typically achieves 50-60% size reduction over PNG at 90% quality with
negligible visual difference.

## When to Use

- After capturing documentation screenshots with Playwright
- When adding screenshot artifacts to project folders
- When asked to optimize or compress images in the repo
- Before committing PNG screenshots to version control

## Conversion Process

Use `sharp-cli` via npx — it requires no installation beyond Node.js and has
full WebP support.

### 1. Convert PNGs to WebP

```bash
cd /path/to/screenshots
for f in *.png; do
  npx sharp-cli -i "$f" -o "${f%.png}.webp" --quality 90
done
```

Quality setting: **90** is the default recommendation. Use 85 for further
compression when file size is a priority over fidelity.

### 2. Verify Size Reduction

```bash
echo "PNG total:" && du -ch *.png | tail -1
echo "WebP total:" && du -ch *.webp | tail -1
```

Expected reduction: 50-60% at quality 90.

### 3. Remove Original PNGs

After confirming the WebP files look correct:

```bash
rm *.png
```

## Playwright Integration

When capturing screenshots with Playwright MCP for documentation, Playwright
only outputs PNG or JPEG. Capture as PNG first, then batch-convert:

```bash
# Playwright captures
browser_take_screenshot --type png --filename screenshots/01-feature.png
browser_take_screenshot --type png --filename screenshots/02-feature.png

# Batch convert
cd screenshots
for f in *.png; do npx sharp-cli -i "$f" -o "${f%.png}.webp" --quality 90; done
rm *.png
```

## Naming Convention

Use zero-padded numbered prefixes for ordered documentation screenshots:

```
01-media-list-view.webp
02-media-grid-view.webp
03-detail-panel-open.webp
04-detail-panel-edit-mode.webp
```

## Notes

- `sharp-cli` is not a project dependency — it runs via `npx` on demand and is
  cached locally after first use
- WebP is supported by all modern browsers and image viewers
- For non-screenshot images (photos, illustrations), quality 85 may be more
  appropriate
