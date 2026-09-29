---
name: maestro-testing
description:
  Write and run Maestro flows for automated testing of mobile apps, WebViews,
  and web browsers. Covers flow file YAML syntax, element selectors, CLI
  commands, simulator/emulator setup, web browser testing, debugging, and
  project structure. Use when the user needs to automate mobile UI testing,
  write Maestro flow files, set up simulators for testing, debug failing flows,
  or test web apps with Maestro. Triggers when user says "test the mobile app",
  "write a Maestro flow", "run Maestro tests", "set up iOS simulator for
  testing", "automate mobile UI", "debug Maestro flow", "Maestro web testing",
  or wants to create or run automated tests with Maestro. For cross-browser web
  testing (Firefox, Safari), use Playwright instead.
---

# Maestro Testing

Maestro is a declarative YAML-based testing framework for mobile apps
(iOS/Android), WebViews, and web browsers (Chromium). It interacts with apps
through the UI/accessibility layer — the same way a user would — without
requiring code instrumentation or framework-specific hooks.

## When to Use

- Writing or running automated tests for a mobile app (iOS simulator or Android
  emulator)
- Testing hybrid apps that mix native UI and WebView content
- Testing web apps via Chromium (beta) using the same YAML syntax as mobile
- Setting up simulators or emulators for test execution
- Debugging failing Maestro flows
- Creating reusable test flows (login, navigation, form submission)

## Maestro vs Playwright

Both tools automate UI testing but operate at different layers:

| Aspect              | Maestro                                  | Playwright                            |
| ------------------- | ---------------------------------------- | ------------------------------------- |
| **Primary surface** | Mobile native + WebView + web            | Web browsers                          |
| **Browsers**        | Chromium only (beta)                     | Chromium, Firefox, WebKit (Safari)    |
| **Test format**     | Declarative YAML                         | Code (JS/TS/Python/Java/.NET)         |
| **Native apps**     | Full support (iOS/Android)               | No native app support                 |
| **Device access**   | Permissions, biometrics, location        | Browser APIs only                     |
| **Best for**        | Mobile-first testing, unified mobile+web | Cross-browser web, complex automation |

**When to use which:**

- **Maestro only** — mobile-only apps, or apps where Chromium web coverage is
  sufficient
- **Playwright only** — web-only apps that need multi-browser testing
- **Both together** — apps with mobile + web surfaces: Maestro handles the
  mobile/native surface, Playwright handles comprehensive cross-browser web
  testing

## Prerequisites

### Install Maestro

```bash
# macOS (Homebrew)
brew tap mobile-dev-inc/tap
brew install mobile-dev-inc/tap/maestro

# macOS, Linux, Windows/WSL (curl)
curl -fsSL "https://get.maestro.mobile.dev" | bash
```

### Platform Requirements

- **iOS**: macOS with Xcode and iOS Simulator installed
- **Android**: Android SDK with at least one emulator AVD configured
- **Web**: No additional setup — Maestro downloads a managed Chromium on first
  run

## Simulator & Emulator Setup

### iOS Simulator

```bash
# List available simulators
xcrun simctl list devices available | grep iPhone

# Boot a simulator
xcrun simctl boot "iPhone 16 Pro" 2>/dev/null || true
open -a Simulator

# Shutdown
xcrun simctl shutdown all

# Erase simulator state (fresh start)
xcrun simctl erase "iPhone 16 Pro"
```

### Android Emulator

```bash
# List available AVDs
emulator -list-avds

# Launch an emulator
emulator -avd <avd_name> &

# Verify device is connected
adb devices
```

### Verify Maestro Can See the Device

```bash
# Should list your running simulator/emulator
maestro hierarchy
```

## Flow File Fundamentals

### Minimal Mobile Flow

```yaml
appId: com.example.myapp
---
- launchApp
- tapOn: "Sign In"
- assertVisible: "Welcome"
```

### Minimal Web Flow

```yaml
url: https://example.com
---
- launchApp
- tapOn: "Get Started"
- assertVisible: "Dashboard"
```

The only difference between mobile and web flows is the header: `appId` for
mobile apps, `url` for web. All commands work the same way.

### Flow Configuration

```yaml
appId: com.example.myapp
name: Login Smoke Test
tags:
  - smoke
  - login
env:
  USERNAME: user@example.com
  PASSWORD: secret123
onFlowStart:
  - runFlow: setup.yaml
onFlowComplete:
  - runFlow: teardown.yaml
---
- launchApp
```

### Core Commands

| Command                 | Purpose                            | Example                                            |
| ----------------------- | ---------------------------------- | -------------------------------------------------- |
| `launchApp`             | Launch the app (or reload web URL) | `- launchApp` or `- launchApp: {clearState: true}` |
| `tapOn`                 | Tap an element                     | `- tapOn: "Submit"`                                |
| `assertVisible`         | Assert element is visible          | `- assertVisible: "Welcome"`                       |
| `assertNotVisible`      | Assert element is NOT visible      | `- assertNotVisible: "Error"`                      |
| `inputText`             | Type text into focused field       | `- inputText: "hello@example.com"`                 |
| `eraseText`             | Erase characters from field        | `- eraseText: {charactersToErase: 20}`             |
| `pressKey`              | Press a key                        | `- pressKey: Enter`                                |
| `back`                  | Press back/navigate back           | `- back`                                           |
| `hideKeyboard`          | Dismiss the keyboard               | `- hideKeyboard`                                   |
| `scrollUntilVisible`    | Scroll until element appears       | See example below                                  |
| `swipe`                 | Swipe gesture                      | `- swipe: {start: "50%,90%", end: "50%,10%"}`      |
| `waitForAnimationToEnd` | Wait for animations to settle      | `- waitForAnimationToEnd`                          |
| `runFlow`               | Execute another flow file          | `- runFlow: login.yaml`                            |
| `runScript`             | Execute JavaScript                 | `- runScript: validate.js`                         |
| `repeat`                | Loop commands                      | See example below                                  |
| `copyTextFrom`          | Copy text from element             | `- copyTextFrom: {id: "title"}`                    |
| `openLink`              | Open a URL/deep link               | `- openLink: "myapp://settings"`                   |
| `takeScreenshot`        | Capture a screenshot               | `- takeScreenshot: step-name`                      |

### scrollUntilVisible

```yaml
- scrollUntilVisible:
    element:
      text: "Settings"
    direction: DOWN
    timeout: 10000
    speed: 40
```

### repeat

```yaml
- repeat:
    times: 3
    commands:
      - tapOn: "Next"
      - assertVisible: "Page .*"
```

## Element Selectors

### Basic Selectors

```yaml
- tapOn:
    text: "Submit" # Match by visible text or accessibility label (regex)
    id: "submit_btn" # Match by accessibility ID (regex)
    index: 0 # 0-based index when multiple elements match
    point: 50%, 50% # Relative screen position
    enabled: true # Filter by enabled state
```

### Relative Selectors

```yaml
- tapOn:
    below: "Email" # Element below "Email"
    above: { id: "footer" } # Element above footer
    leftOf: "Delete" # Element left of "Delete"
    rightOf: "Cancel" # Element right of "Cancel"
    containsChild: "Item 1" # Parent containing "Item 1"
    childOf: { id: "list" } # Child inside element with id "list"
```

### Platform-Specific Accessibility IDs

| Platform     | Property                           | Maps to Maestro |
| ------------ | ---------------------------------- | --------------- |
| UIKit        | `accessibilityIdentifier`          | `id`            |
| SwiftUI      | `.accessibilityIdentifier("name")` | `id`            |
| React Native | `testID="name"`                    | `id`            |
| Android      | `contentDescription`               | `id`            |
| Web/HTML     | `data-testid` or `id`              | `id`            |

## Running Tests

```bash
# Single flow
maestro test login.yaml

# Run all flows in a directory
maestro test maestro/

# Pass environment variables
maestro test -e USERNAME=test@example.com -e PASSWORD=secret login.yaml

# Generate JUnit report
maestro test --format junit --output results.xml maestro/

# Generate HTML report
maestro test --format html --output report.html maestro/

# Record execution as video
maestro record login.yaml

# Interactive visual debugging
maestro studio
```

## Project Structure

Recommended layout for Maestro flows in a project:

```
project-root/
├── maestro/                    # or apps/mobile/maestro/ in a monorepo
│   ├── login.yaml              # Reusable login flow
│   ├── setup.yaml              # Shared setup (called via onFlowStart)
│   ├── teardown.yaml           # Shared teardown (called via onFlowComplete)
│   ├── smoke/
│   │   ├── home-screen.yaml
│   │   └── navigation.yaml
│   ├── features/
│   │   ├── create-document.yaml
│   │   └── search.yaml
│   └── scripts/
│       └── helpers.js          # JavaScript helpers for runScript
```

**Conventions:**

- Group flows by purpose: `smoke/`, `features/`, `regression/`
- Extract shared flows (login, setup) and call them with `runFlow`
- Use `onFlowStart`/`onFlowComplete` hooks for setup and teardown
- Run suites by directory: `maestro test maestro/smoke/`

## Common Patterns

### Parameterized Login

```yaml
appId: com.example.myapp
env:
  USERNAME: ${USERNAME || "test@example.com"}
  PASSWORD: ${PASSWORD || "password123"}
---
- launchApp:
    clearState: true
- tapOn:
    id: "email_field"
- inputText: ${USERNAME}
- tapOn:
    id: "password_field"
- inputText: ${PASSWORD}
- tapOn: "Sign In"
- assertVisible: "Home"
```

Run with custom credentials:

```bash
maestro test -e USERNAME=admin@company.com -e PASSWORD=s3cret login.yaml
```

### Navigation and Assertion

```yaml
- tapOn: "Settings"
- assertVisible: "Account"
- tapOn: "Account"
- assertVisible: "Edit Profile"
- back
- assertVisible: "Settings"
```

### Scrolling to Find an Element

```yaml
- scrollUntilVisible:
    element:
      text: "Delete Account"
    direction: DOWN
    timeout: 15000
- tapOn: "Delete Account"
```

### Web Browser Flow

```yaml
url: https://myapp.example.com
---
- launchApp
- tapOn: "Log In"
- tapOn:
    id: "email"
- inputText: "user@example.com"
- tapOn:
    id: "password"
- inputText: "password123"
- tapOn: "Submit"
- assertVisible: "Dashboard"
```

## Environment Variables & Parameterization

### Flow-Level Defaults

```yaml
env:
  API_URL: http://localhost:3000
  TIMEOUT: 5000
---
- launchApp
```

### CLI Override

```bash
maestro test -e API_URL=https://staging.example.com flow.yaml
```

### Shell Environment

Maestro automatically picks up shell variables prefixed with `MAESTRO_`:

```bash
export MAESTRO_USERNAME=admin
# Available as ${MAESTRO_USERNAME} in flows
```

### Passing to Subflows

```yaml
- runFlow:
    file: login.yaml
    env:
      USERNAME: ${TEST_USER}
      PASSWORD: ${TEST_PASS}
```

### JavaScript Integration

```yaml
- runScript: compute.js
- tapOn: ${output.compute.result}
```

```javascript
// compute.js
var result = MY_VARIABLE.toUpperCase();
output.compute = { result: result };
```

## Debugging Failed Flows

### Interactive Debugging

```bash
# Launch Maestro Studio — visual test builder with live device view
maestro studio
```

Studio lets you see the element hierarchy, try selectors, and build commands
interactively.

### Inspect Element Hierarchy

```bash
# Print the current UI hierarchy (useful for finding selectors)
maestro hierarchy
```

### Common Failures

| Symptom                         | Likely cause                      | Fix                                                   |
| ------------------------------- | --------------------------------- | ----------------------------------------------------- |
| Element not found               | Wrong text/id, element not loaded | Check with `maestro hierarchy`, add wait              |
| Timeout                         | Animation or loading delay        | Increase timeout, add `waitForAnimationToEnd`         |
| Wrong element tapped            | Multiple matches                  | Add `index`, use relative selectors                   |
| Flow works locally, fails in CI | Timing differences                | Add explicit waits, increase timeouts                 |
| Simulator/emulator not found    | Device not booted                 | Boot device before running, check `xcrun simctl list` |

### Timeout Tuning

Individual command timeouts:

```yaml
- assertVisible:
    text: "Loaded"
    enabled: true
  # Default timeout is ~5s for assertions
```

Scroll timeout:

```yaml
- scrollUntilVisible:
    element: "Footer"
    timeout: 30000 # 30 seconds
```

## Context7 Reference

For the latest Maestro documentation, query Context7:

- **Library ID:** `/mobile-dev-inc/maestro-docs`
- **Example query:** "How to use scrollUntilVisible with nested elements"
- **Snippet count:** 800+ code examples available

Use Context7 when you need details on a specific command, selector, or
configuration option not covered in this reference.

## Quick Reference

```
maestro test <flow.yaml>           Run a single flow
maestro test <directory/>          Run all flows in directory
maestro test -e KEY=val <flow>     Pass environment variable
maestro test --format junit <dir>  Generate JUnit report
maestro record <flow.yaml>         Record execution as MP4
maestro studio                     Interactive visual debugger
maestro hierarchy                  Print current UI hierarchy

Flow header:  appId: com.example.app   (mobile)
              url: https://example.com  (web)

Key commands: launchApp, tapOn, assertVisible, inputText, pressKey,
              scrollUntilVisible, swipe, back, hideKeyboard, runFlow,
              runScript, repeat, takeScreenshot, waitForAnimationToEnd

Selectors:    text: "Label"    id: "accessibilityId"    point: 50%,50%
              index: 0         below: "X"               containsChild: "Y"
```
