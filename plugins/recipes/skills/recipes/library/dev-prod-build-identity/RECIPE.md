# Dev/Prod Build Identity Recipe

## Purpose

Set up a system where development and production builds of the same application
have distinct identities -- different app names, icons, bundle IDs, and data
directories -- so both can be installed and run simultaneously on the same
machine or device. This lets developers use their own app as a real user
(production build) while testing new features in a visually distinct development
build, without either build interfering with the other.

This recipe is a hybrid: the architecture pattern is technology-agnostic, but
implementation guidance is provided for three common stacks (Electron,
Expo/React Native, and server-side Node/Bun APIs).

## When to Use

- You want to install both a development and production build on the same
  machine or device
- You're building a desktop or mobile app and need to test new features without
  overwriting your production install
- You want visual differentiation (icons, titles) so you never accidentally use
  the wrong build
- You need data isolation between dev and prod so testing doesn't corrupt
  production data
- You're setting up a monorepo with multiple apps that each need dev/prod
  variants

## Architecture Overview

### The Side-by-Side Problem

When you build an app in development, it typically uses the same bundle ID, app
name, and data directory as the production version. Installing the dev build
overwrites the production build. You lose your real data and can't use both
simultaneously.

### The Solution: Distinct Identity Per Build Variant

Every touchpoint where the OS or device identifies the app must differ between
variants:

```
PRODUCTION BUILD                    DEVELOPMENT BUILD
─────────────────                   ─────────────────
App Name: "MyApp"                   App Name: "MyApp Dev"
Bundle ID: com.myapp                Bundle ID: com.myapp.dev
Icon: Black background              Icon: Purple background
Data Dir: ~/MyApp/                  Data Dir: ~/MyAppDev/
Database: myapp.db                  Database: myapp.dev.db
URL Scheme: myapp://                URL Scheme: myapp-dev://
API URL: https://api.myapp.com      API URL: http://localhost:3011
```

### Three Layers of Separation

**1. Build-time identity** (OS-level, prevents overwrite):

- Bundle ID / app ID (e.g., `com.myapp` vs `com.myapp.dev`)
- Product name (what appears in the OS app launcher)
- Icon assets (visually distinct at a glance)
- Artifact name (installer/package filename)

**2. Runtime configuration** (app-level, prevents data collision):

- Data directory name (separate filesystem locations)
- Database filename (separate SQLite files)
- Storage key prefix (separate localStorage/AsyncStorage namespaces)
- URL scheme (separate deep links)

**3. Environment variables** (connection-level, points to correct services):

- API URL (localhost vs production server)
- Sync service URL
- Debug flags
- Feature toggles

### Key Design Decisions

**Why separate icons?** Because you WILL forget which build you're running. A
purple icon (dev) vs black icon (prod) provides instant recognition in the dock,
taskbar, or home screen. This is the single most important visual cue.

**Why separate data directories?** Database operations during development
(migrations, test data, schema experiments) must never touch production data.
Separate directories provide complete isolation without any code-level
filtering.

**Why dotenv-flow?** It provides cascading environment files (`.env` →
`.env.{NODE_ENV}` → `.env.local`) with no custom code. The `NODE_ENV` variable
selects which override file loads, and `.env.local` (gitignored) handles
machine-specific values like local IP addresses.

**Why NOT feature flags?** Build identity is about OS-level separation (bundle
IDs, icons, data paths), not runtime behavior toggling. Feature flags solve a
different problem. Build identity must be set at build/install time, not toggled
at runtime.

## Implementation Process

### Phase 1: Environment Files

Set up environment variable cascading with `dotenv-flow`.

**1.1 Install dotenv-flow**

```bash
npm install dotenv-flow
# or
pnpm add dotenv-flow
```

**1.2 Create environment files**

Create these files in each app's root:

```
.env                  # Base development configuration (committed)
.env.production       # Production overrides (committed)
.env.local            # Machine-specific overrides (gitignored)
.env.example          # Template documenting all variables (committed)
```

**1.3 Define variant-specific variables**

`.env` (development defaults):

```env
# App identity
APP_NAME="MyApp Dev"
PRODUCT_NAME="MyApp-Dev"

# App variant (development | production)
APP_VARIANT=development

# API endpoint
API_URL=http://localhost:3011
```

`.env.production` (production overrides):

```env
APP_NAME="MyApp"
PRODUCT_NAME="MyApp"
APP_VARIANT=production
API_URL=https://api.myapp.com
```

`.env.example` (template with documentation):

```env
# App display name (shown in UI, window titles)
APP_NAME="MyApp Dev"

# Product name for OS-level packaging (installer name, .app bundle name)
PRODUCT_NAME="MyApp-Dev"

# App variant controls identity separation:
# - 'development': Uses .dev bundle ID suffix, dev icons, separate data dir
# - 'production': Uses standard bundle ID, prod icons, production data dir
APP_VARIANT=development

# API URL (use .env.local for machine-specific IP on physical devices)
API_URL=http://localhost:3011
```

**1.4 Add .env.local to .gitignore**

```gitignore
.env.local
.env.*.local
```

**1.5 Load in your app entry point**

```typescript
// Must be the FIRST import in your entry file
import "dotenv-flow/config";
```

For Vite-based apps, environment variables prefixed with `VITE_` are
automatically available in the renderer via `import.meta.env.VITE_*`.

For Expo apps, variables prefixed with `EXPO_PUBLIC_` are available at runtime
via `expo-constants`.

**Validate:** Run your app in dev mode and verify the correct variables are
loaded. Add a console log of the app name to confirm.

### Phase 2: Icon Assets

Create visually distinct icon sets for each variant.

**2.1 Organize icon directories**

```
resources/           # or assets/images/
├── dev/
│   ├── icon.png     # Primary icon (1024x1024)
│   ├── icon.icns    # macOS (Electron only)
│   ├── icon.ico     # Windows (Electron only)
│   └── icon.svg     # Source SVG
├── prod/
│   ├── icon.png
│   ├── icon.icns
│   ├── icon.ico
│   └── icon.svg
```

For Expo/React Native, include platform-specific variants:

```
assets/images/
├── dev/
│   ├── icon.png                    # iOS + Android base (1024x1024)
│   ├── android-icon-foreground.png # Adaptive icon foreground (1024x1024)
│   ├── android-icon-background.png # Adaptive icon background (1024x1024)
│   ├── android-icon-monochrome.png # Material You themed icon (1024x1024)
│   └── splash-icon.png            # Splash screen icon (1200x1200)
├── prod/
│   ├── icon.png
│   ├── android-icon-foreground.png
│   ├── android-icon-background.png
│   ├── android-icon-monochrome.png
│   └── splash-icon.png
```

**2.2 Design dev icons for instant recognition**

The dev icon must be immediately distinguishable from production at small sizes
(dock icons, taskbar, phone home screen). Effective strategies:

- **Different background color** (e.g., purple/violet for dev, black for prod).
  This is the simplest and most effective approach.
- **Colored border or ribbon** with "DEV" text
- **Color shift** of the entire palette (blue → orange)

Avoid subtle differences (slight opacity changes, small badges) -- they're
invisible at small sizes.

**Validate:** Place both icons side by side at 32x32 and 64x64. Can you tell
them apart instantly?

### Phase 3: Centralized App Configuration

Create a single configuration module that derives all identity values from the
build variant.

**3.1 Create the app config module**

This is the central source of truth for all variant-dependent values:

```typescript
// app-config.ts (or branding.ts for mobile)

// Detect build environment from environment variables
// Priority: explicit build env flag > mode flag > dev server detection > default
const BUILD_ENV = getBuildEnvironment(); // implementation varies by platform
const IS_DEV = BUILD_ENV === "development";

const TECHNICAL_NAME = "myapp"; // Stable, never changes

export const APP_CONFIG = {
  isDevelopmentBuild: IS_DEV,

  // Display name (shown to users)
  displayName: IS_DEV ? `${APP_NAME} [DEV]` : APP_NAME,

  // Stable technical identifier (URIs, MCP, etc.)
  technicalName: TECHNICAL_NAME,

  // Data directory (separate filesystem locations)
  dataDirectoryName: IS_DEV ? "MyAppDev" : "MyApp",

  // Database filename (separate files even if in same directory)
  databaseName: IS_DEV ? `${TECHNICAL_NAME}.dev.db` : `${TECHNICAL_NAME}.db`,

  // URL scheme for deep links
  urlScheme: IS_DEV ? `${TECHNICAL_NAME}-dev://` : `${TECHNICAL_NAME}://`,
} as const;
```

**3.2 Platform-specific environment detection**

**Electron (Vite-based):**

```typescript
// Detection priority for Electron + electron-vite:
const BUILD_ENV =
  import.meta.env.VITE_BUILD_ENV || // Explicit override
  import.meta.env.MODE || // --mode flag (development|production)
  (import.meta.env.DEV ? "development" : "production"); // Dev server detection
```

`import.meta.env.MODE` is set by the `--mode` flag passed to electron-vite. This
is important because `pnpm run dev` (dev server) and `pnpm run build:dev`
(packaged dev build) both need to resolve to `development`.

**Expo/React Native:**

```typescript
import Constants from "expo-constants";

// Read from Expo config extra field (set in app.config.ts)
const appVariant = Constants.expoConfig?.extra?.appVariant;
const IS_DEV = appVariant === "development";
```

The Expo approach reads from `extra` config because environment variables are
baked into the native build at compile time via `app.config.ts`.

**3.3 Use the config everywhere**

Every place in the app that needs variant-aware behavior imports from this
single module. Components, services, and initialization code never detect the
environment themselves.

```typescript
import { APP_CONFIG } from "@shared/app-config";

// Database initialization
const dbPath = join(dataDir, APP_CONFIG.databaseName);

// Window title
window.setTitle(APP_CONFIG.displayName);
```

**Validate:** Run both dev and prod builds. Verify different display names,
database filenames, and data directories.

### Phase 4: Build-Time Identity (Desktop - Electron)

Configure electron-builder to produce distinct app bundles per variant.

**4.1 Base electron-builder config**

`electron-builder.yml` defines production defaults:

```yaml
appId: com.myapp
productName: MyApp
icon: resources/prod/icon
mac:
  artifactName: ${env.ARTIFACT_NAME}-${version}-${arch}.${ext}
win:
  executableName: ${env.PRODUCT_NAME}
nsis:
  artifactName: ${env.ARTIFACT_NAME}-${version}-setup.${ext}
```

Note the `${env.*}` references -- electron-builder reads these from the
environment at build time. This is how the build scripts override identity
fields.

**4.2 Build wrapper scripts**

Create two scripts that set variant-specific env vars and invoke
electron-builder with config overrides:

`scripts/build-dev.js`:

```javascript
const { execSync } = require("child_process");
const path = require("path");
const dotenvFlow = require("dotenv-flow");

// Load .env (development mode)
dotenvFlow.config({
  node_env: "development",
  path: path.join(__dirname, ".."),
});

// Set dev identity
process.env.APP_ID = "com.myapp.dev";
process.env.PRODUCT_NAME = process.env.PRODUCT_NAME || "MyApp-Dev";
process.env.ARTIFACT_NAME = "myapp-dev";

const builderArgs = process.argv.slice(2).join(" ");
const configOverride = [
  `--config.appId="${process.env.APP_ID}"`,
  `--config.productName="${process.env.PRODUCT_NAME}"`,
  `--config.icon="resources/dev/icon"`,
].join(" ");

execSync(`electron-builder ${builderArgs} ${configOverride}`, {
  stdio: "inherit",
  env: process.env,
});
```

`scripts/build-prod.js`:

```javascript
const { execSync } = require("child_process");
const path = require("path");
const dotenvFlow = require("dotenv-flow");

// Load .env.production
dotenvFlow.config({ node_env: "production", path: path.join(__dirname, "..") });

// Set production identity
process.env.APP_ID = "com.myapp";
process.env.PRODUCT_NAME = process.env.PRODUCT_NAME || "MyApp";
process.env.ARTIFACT_NAME = "myapp";

const builderArgs = process.argv.slice(2).join(" ");
const configOverride = [
  `--config.appId="${process.env.APP_ID}"`,
  `--config.productName="${process.env.PRODUCT_NAME}"`,
  `--config.icon="resources/prod/icon"`,
].join(" ");

execSync(`electron-builder ${builderArgs} ${configOverride}`, {
  stdio: "inherit",
  env: process.env,
});
```

**Note on execSync:** These build scripts use `execSync` to invoke
electron-builder as a child process. This is appropriate here because the input
is controlled (developer-defined CLI args, not user input). In application code
that processes user input, always use `execFile` or equivalent safe APIs to
prevent command injection.

**4.3 Package.json scripts**

```json
{
  "scripts": {
    "dev": "electron-vite dev",
    "dev:prod": "electron-vite dev --mode production",
    "build:dev": "electron-vite build --mode development",
    "build:prod": "electron-vite build --mode production",
    "build:mac": "npm run build:prod && node scripts/build-prod.js --mac",
    "build:mac:dev": "npm run build:dev && node scripts/build-dev.js --mac",
    "build:win": "npm run build:prod && node scripts/build-prod.js --win",
    "build:win:dev": "npm run build:dev && node scripts/build-dev.js --win"
  }
}
```

**Key distinction:** `electron-vite build --mode X` compiles the app code with
the correct environment. The build wrapper script then packages the compiled
code into an installer with the correct identity. These are two separate steps.

**4.4 Runtime icon selection (window icon)**

The packaged app icon is set by electron-builder, but the window/taskbar icon is
set in code:

```typescript
import iconProd from "../../resources/prod/icon.png?asset";
import iconDev from "../../resources/dev/icon.png?asset";

const icon = APP_CONFIG.isDevelopmentBuild ? iconDev : iconProd;

const window = new BrowserWindow({
  icon: icon,
  title: APP_CONFIG.displayName,
  // ...
});
```

**Validate:** Build both `build:mac` and `build:mac:dev`. Verify that:

- Both .app bundles can coexist in /Applications
- They have different icons in the dock
- They have different window titles
- They use different data directories (`~/Library/Application Support/`)

### Phase 5: Build-Time Identity (Mobile - Expo)

Configure Expo to produce distinct app builds per variant.

**5.1 Dynamic app.config.ts**

Expo's config file is evaluated at build time, making it the ideal place for
variant-conditional configuration:

```typescript
import { ExpoConfig, ConfigContext } from "expo/config";
import * as dotenvFlow from "dotenv-flow";

dotenvFlow.config();

export default ({ config }: ConfigContext): ExpoConfig => {
  const appVariant =
    process.env.EXPO_PUBLIC_APP_VARIANT || process.env.NODE_ENV || "production";
  const isDev = appVariant === "development";
  const iconFolder = isDev ? "dev" : "prod";
  const iconPath = `./assets/images/${iconFolder}`;

  return {
    ...config,
    name: isDev ? "MyApp Dev" : "MyApp",
    slug: isDev ? "myapp-dev" : "myapp",
    icon: `${iconPath}/icon.png`,
    scheme: isDev ? "myapp-dev" : "myapp",
    ios: {
      bundleIdentifier: isDev ? "com.myapp.dev" : "com.myapp",
    },
    android: {
      package: isDev ? "com.myapp.dev" : "com.myapp",
      adaptiveIcon: {
        foregroundImage: `${iconPath}/android-icon-foreground.png`,
        backgroundImage: `${iconPath}/android-icon-background.png`,
        monochromeImage: `${iconPath}/android-icon-monochrome.png`,
      },
    },
    plugins: [
      [
        "expo-splash-screen",
        {
          image: `${iconPath}/splash-icon.png`,
        },
      ],
    ],
    extra: {
      apiUrl: process.env.EXPO_PUBLIC_API_URL || "https://api.myapp.com",
      appVariant: process.env.EXPO_PUBLIC_APP_VARIANT || "production",
    },
  };
};
```

**5.2 Package.json build scripts**

Set `NODE_ENV` and `EXPO_PUBLIC_APP_VARIANT` explicitly in each script:

```json
{
  "scripts": {
    "ios:dev": "NODE_ENV=development EXPO_PUBLIC_APP_VARIANT=development expo run:ios",
    "ios:prod": "NODE_ENV=production EXPO_PUBLIC_APP_VARIANT=production expo run:ios",
    "android:dev": "NODE_ENV=development EXPO_PUBLIC_APP_VARIANT=development expo run:android",
    "android:prod": "NODE_ENV=production EXPO_PUBLIC_APP_VARIANT=production expo run:android",
    "ios:release:dev": "NODE_ENV=development EXPO_PUBLIC_APP_VARIANT=development expo run:ios --configuration Release",
    "ios:release:prod": "NODE_ENV=production EXPO_PUBLIC_APP_VARIANT=production expo run:ios --configuration Release",
    "android:release:dev": "NODE_ENV=development EXPO_PUBLIC_APP_VARIANT=development expo run:android --variant release",
    "android:release:prod": "NODE_ENV=production EXPO_PUBLIC_APP_VARIANT=production expo run:android --variant release"
  }
}
```

**Why set both NODE_ENV and your app variant variable in Expo scripts?**
`NODE_ENV` controls which `.env` files `dotenv-flow` loads.
`EXPO_PUBLIC_APP_VARIANT` is the explicit variant flag baked into the Expo
config. They serve different purposes and both are needed because dotenv-flow
runs at config evaluation time, while the variant flag propagates into the
runtime bundle.

**5.3 Runtime branding module**

```typescript
import Constants from "expo-constants";

export function getAppVariant(): "development" | "production" {
  const variant = Constants.expoConfig?.extra?.appVariant;
  return variant === "development" ? "development" : "production";
}

export function getAppBranding() {
  const isDev = getAppVariant() === "development";

  return {
    displayName: isDev ? "MyApp Dev" : "MyApp",
    databaseName: isDev ? "myapp.dev.db" : "myapp.db",
    storageKeyPrefix: isDev ? "myapp-dev" : "myapp",
    urlScheme: isDev ? "myapp-dev" : "myapp",
  } as const;
}
```

**Validate:** Build both `ios:dev` and `ios:prod` (or the Android equivalents)
and install both on the same device/simulator. Verify:

- Both apps appear in the home screen with different names and icons
- Both apps can be open simultaneously
- Data created in one doesn't appear in the other

### Phase 6: API Environment Configuration

The API server typically doesn't need build variants (there's only one running
instance), but it does need environment-aware configuration that the client apps
connect to.

**6.1 Environment-variable-driven config with validation**

```typescript
// Load environment files first
import "dotenv-flow/config";

import { z } from "zod";

const envSchema = z.object({
  DATABASE_URL: z.string(),
  API_PORT: z.string().default("3011"),
  ALLOWED_ORIGINS: z.string(),
  // Feature detection: enable features based on presence of keys
  SMTP_HOST: z.string().optional(),
  AI_API_KEY: z.string().optional(),
  DEBUG_PROMPTS: z.string().optional(),
});

const parsed = envSchema.safeParse(process.env);
if (!parsed.success) {
  console.error("Environment validation failed:", parsed.error.format());
  process.exit(1);
}

export const env = parsed.data;
```

**Key insight:** The API uses feature detection (is `SMTP_HOST` set?) rather
than environment detection (is `NODE_ENV` production?). This is more flexible --
features activate based on what credentials are available, not what environment
label is set.

**6.2 CORS must include both dev and prod client origins**

```typescript
// Trusted origins must include client app URL schemes for mobile
const trustedOrigins = [
  ...env.ALLOWED_ORIGINS.split(",").map((s) => s.trim()),
  "myapp://",
  "myapp://*",
  "myapp-dev://",
  "myapp-dev://*",
];
```

**6.3 Development vs production .env for the API**

`.env` (development):

```env
DATABASE_URL=postgresql://user:pass@localhost:5432/myapp
ALLOWED_ORIGINS="http://localhost:3000,http://localhost:5173"
DEBUG_PROMPTS=true
```

`.env.production`:

```env
# Values provided at runtime via environment variables or Docker
# DATABASE_URL, ALLOWED_ORIGINS, etc. are set in deployment config
```

**Validate:** Start the API with `dotenv-flow` in development mode. Verify CORS
allows requests from your dev client URL. Start with production env and verify
debug logging is off.

## Integration Points

### Monorepo Coordination (Turborepo)

If using Turborepo, list environment variables in `turbo.json` `globalEnv` so
that changes to environment variables invalidate the build cache:

```json
{
  "globalEnv": [
    "DATABASE_URL",
    "API_URL",
    "APP_VARIANT",
    "ALLOWED_ORIGINS",
    "DEBUG_PROMPTS"
  ]
}
```

Without this, Turborepo may serve a cached build that was compiled with
different environment values.

### Cloud Sync (PowerSync, Firebase, etc.)

If your app uses cloud sync, ensure sync credentials point to the correct
backend for each variant. The dev build should sync with a development database,
not the production one. The API URL in your `.env` files controls this
automatically, but verify that your sync service configuration also reads from
environment variables.

### Deep Links / URL Schemes

Both variants register different URL schemes (`myapp://` vs `myapp-dev://`). The
API's trusted origins list must include both schemes. If using OAuth callbacks
or deep links, ensure the redirect URIs are registered for both variants.

### Database Migrations

Both variants use separate database files but typically share the same schema.
Run migrations on both databases when the schema changes. In development, it's
common to use `db:push` (destructive schema sync) on the dev database while
using proper migrations on the production database.

## Settings / Configuration

| Setting        | Dev Value             | Prod Value            | Where Set                     |
| -------------- | --------------------- | --------------------- | ----------------------------- |
| App Name       | "MyApp Dev"           | "MyApp"               | `.env` / `.env.production`    |
| Bundle ID      | com.myapp.dev         | com.myapp             | Build script / app.config.ts  |
| Icon           | resources/dev/icon    | resources/prod/icon   | Build script / app.config.ts  |
| Data Directory | MyAppDev              | MyApp                 | app-config.ts                 |
| Database       | myapp.dev.db          | myapp.db              | app-config.ts                 |
| API URL        | http://localhost:3011 | https://api.myapp.com | `.env` / `.env.production`    |
| URL Scheme     | myapp-dev://          | myapp://              | app-config.ts / app.config.ts |
| Debug Logging  | Enabled               | Disabled              | `.env`                        |

## Adapting to Different Tech Stacks

### Electron Alternatives (Tauri, NW.js)

The core pattern is identical: separate build configs per variant with different
app IDs and icons. Tauri uses `tauri.conf.json` where you'd override
`identifier` and `icon` per variant. The centralized app-config module pattern
works regardless of the desktop framework.

### React Native without Expo

Without Expo's `app.config.ts`, configure variants via:

- **iOS:** Xcode build configurations (Debug-Dev, Release-Dev, Debug-Prod,
  Release-Prod) with different bundle IDs and asset catalogs
- **Android:** Gradle build flavors (`dev` and `prod`) with different
  `applicationId` and resource directories
- The runtime branding module reads from a native config bridge instead of Expo
  Constants

### Flutter

Flutter uses `--dart-define` for build-time configuration and flavors for
variant-specific assets. The pattern maps to:

- `--dart-define=APP_VARIANT=development`
- Separate asset directories per flavor
- Different `applicationId` in `build.gradle` flavors

### Environment Variable Libraries

`dotenv-flow` is recommended because it handles cascading automatically. Other
options:

- **dotenv** -- simpler, no cascading (you'd load the right file manually)
- **env-cmd** -- loads a specific env file before running a command
- **cross-env** -- sets env vars cross-platform in npm scripts (useful with
  Expo)

## Gotchas & Important Notes

- **The `.dev` bundle ID suffix is a convention, not a requirement.** Use
  whatever suffix makes sense for your project, but `.dev` is widely understood
  and immediately communicates the purpose. Some teams use `.staging`, `.beta`,
  etc. for additional variants.

- **Data directory separation is non-negotiable.** Even if you skip icon
  differentiation, you MUST separate data directories and database files.
  Running a dev migration on your production database is a disaster that's hard
  to recover from.

- **dotenv-flow loads `.env` first, then overlays.** The base `.env` file is
  always loaded. `.env.production` only overrides the values it explicitly sets.
  This means your `.env` should contain development defaults, and
  `.env.production` should only contain values that differ in production.

- **`.env.local` is for machine-specific values only.** Things like your local
  network IP address (needed for mobile development on physical devices) go in
  `.env.local`, which is gitignored. Never put variant-specific configuration
  here -- it should be in `.env` or `.env.production`.

- **Expo requires a fresh native build when changing bundle IDs.** If you switch
  between `ios:dev` and `ios:prod`, Expo must regenerate the native project
  because the bundle identifier changes. This is expected -- it's building a
  genuinely different app. Metro hot reload alone is not sufficient.

- **Electron-builder's `${env.*}` syntax reads from `process.env`.** The build
  wrapper scripts set environment variables that electron-builder.yml references
  via `${env.ARTIFACT_NAME}`, `${env.PRODUCT_NAME}`, etc. If these aren't set,
  electron-builder uses the YAML defaults. This is intentional -- the YAML
  defaults are production values, and the scripts override for dev.

- **Set both NODE_ENV and your app variant variable in Expo scripts.**
  `NODE_ENV` controls dotenv-flow file loading. The app variant variable (e.g.,
  `EXPO_PUBLIC_APP_VARIANT`) is baked into the Expo config at build time. They
  serve different purposes and both are needed.

- **Window titles should include a `[DEV]` suffix.** This catches the case where
  the dock/taskbar icon is too small to distinguish. The window title provides a
  second visual cue.

- **Don't forget to update the API's trusted origins when adding a new
  variant.** If your mobile app uses URL schemes for auth callbacks (e.g., OAuth
  redirect), the API must trust both `myapp://` and `myapp-dev://`. Missing this
  causes auth to silently fail only in development builds -- a confusing bug.

- **Icon generation tip.** Design one master SVG with a parameterized background
  color. Generate all icon sizes and formats from this single source. When you
  change the dev color from purple to orange, regenerate all formats at once.
  This prevents mismatched icon sets.

- **`pnpm run dev` is not the same as `pnpm run build:dev`.** The first runs a
  dev server with hot reload (for active development). The second compiles and
  packages a distributable dev build (for installing alongside production). They
  both use development environment settings, but serve very different purposes.
