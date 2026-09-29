# QR Code Local Pairing Recipe

## Purpose

Implement a device pairing flow where one app (the generator) displays a QR code
encoding a local connection URL, and a mobile app (the scanner) scans it to
establish a connection. This eliminates manual IP address / port entry for
LAN-based communication between apps.

This recipe is a **hybrid**: the architecture is technology-agnostic (any QR
library, any camera library, any backend), but implementation guidance
references specific stacks (Expo/React Native for mobile, Tauri/Rust for
desktop) with notes on adapting to other platforms.

## When to Use

- A mobile app needs to connect to a local server, desktop app, or API on the
  same network
- You want instant pairing without requiring the user to manually type an IP
  address
- The connection target has a dynamic IP or auto-assigned port
- Both devices are on the same local network (WiFi / LAN)

## Architecture Overview

### Mental Model

The pattern has two roles:

```
┌──────────────┐                      ┌──────────────┐
│  Generator   │                      │   Scanner    │
│  (any app)   │                      │ (mobile app) │
│              │                      │              │
│ 1. Start     │                      │              │
│    service   │                      │              │
│ 2. Detect    │                      │              │
│    local IP  │                      │              │
│ 3. Encode    │    user scans QR     │ 4. Scan QR   │
│    QR code   │  ─────────────────>  │ 5. Validate  │
│ 4. Display   │                      │    URL       │
│    QR + text │                      │ 6. Connect   │
│    fallback  │                      │    to URL    │
└──────────────┘                      └──────────────┘
```

**Generator** — any app that runs a network service and needs clients to find
it. Determines its own LAN IP, encodes `{scheme}://{ip}:{port}` as a QR code.

**Scanner** — a mobile app with camera access. Scans the QR, validates the URL
scheme, and connects.

### Key Design Decisions

**QR code contains only the URL.** Don't encode authentication tokens, session
IDs, or complex payloads in the QR. Keep it simple: `ws://192.168.1.42:9876` or
`http://192.168.1.42:3000`. If you need auth, handle it after connection. This
keeps the QR small (faster to scan), human-readable (debuggable), and
security-appropriate (QR codes are visible on screen).

**Always provide a manual fallback.** Not all devices have cameras. QR scanning
fails in poor lighting. Corporate environments may restrict camera access. A
simple IP + port text input costs almost nothing to implement and saves users
when QR fails.

**Validate URL scheme before connecting.** The scanner should check that the
scanned data starts with an expected scheme (`ws://`, `http://`, etc.). This
prevents the app from trying to connect to arbitrary URLs from random QR codes
(promotional materials, product barcodes, etc.).

**Scan lock is mandatory.** Camera-based QR scanners fire their callback on
every video frame that detects a code — often 30+ times per second. Without a
lock, you'll trigger dozens of duplicate connection attempts. Set a flag on
first scan, and reset it when the user navigates back to the scan screen.

### Trade-offs

- **No authentication** — this pattern assumes a trusted local network. Suitable
  for personal use, development, and LAN-only apps. For internet-facing use, add
  token-based auth after connection.
- **No mDNS/Bonjour** — QR scanning is simpler than service discovery protocols.
  It works on any network without multicast DNS support. The tradeoff is that it
  requires visual line-of-sight between devices.
- **IP may change** — if the generator's IP changes (DHCP renewal, network
  switch), the QR code becomes stale. For long-running services, consider
  periodic QR refresh or mDNS as an alternative.

## Implementation Process

### Phase 1: Generator — Local IP Detection

The generator needs to know its own LAN IP address. Every platform provides
this, but the APIs differ.

**Pattern:**

```
function getLocalIp():
  ip = detectNetworkIp()     // Platform-specific
  if ip is null:
    return "127.0.0.1"       // Safe fallback
  return ip
```

**Platform-specific detection:**

| Platform | Approach                                                          |
| -------- | ----------------------------------------------------------------- |
| Rust     | `local-ip-address` crate: `local_ip().map(\|ip\| ip.to_string())` |
| Node.js  | `os.networkInterfaces()` — filter for non-internal IPv4           |
| Python   | `socket.gethostbyname(socket.gethostname())`                      |
| Go       | `net.InterfaceAddrs()` — filter for non-loopback                  |
| Swift    | `getifaddrs()` — filter for `AF_INET` + `en0`/`en1`               |

**Gotcha: Multiple interfaces.** Machines with Ethernet + WiFi, or VPN active,
may have multiple IPs. The auto-detected one may not be reachable from the
mobile device. The manual fallback handles this — users can enter the correct IP
if auto-detection picks the wrong interface.

**Validate:** Print or log the detected IP. Verify it matches what you see in
your system's network settings.

### Phase 2: Generator — QR Code Display

Construct the URL and render it as a QR code.

**URL format:**

```
{scheme}://{local_ip}:{port}
```

Examples:

- `ws://192.168.1.42:9876` (WebSocket)
- `http://192.168.1.42:3000` (HTTP API)
- `wss://192.168.1.42:9876` (Secure WebSocket)

**QR code libraries by platform:**

| Platform     | Library                                      | Notes                               |
| ------------ | -------------------------------------------- | ----------------------------------- |
| React        | `qrcode.react`                               | `<QRCodeSVG>` component, SVG output |
| Vue          | `qrcode.vue`                                 | Wrapper around `qrcode`             |
| Swift/UIKit  | `CoreImage` CIFilter                         | Built-in, no dependency             |
| Kotlin       | `com.google.zxing`                           | Standard barcode library            |
| Python       | `qrcode`                                     | PIL/Pillow image output             |
| Terminal/CLI | `qrcode-terminal` (npm) or `qrcode` (Python) | ASCII art QR                        |

**Always display the raw URL as text** alongside the QR code. This serves as
both a manual fallback and a debugging aid.

**Example (React):**

```tsx
import { QRCodeSVG } from "qrcode.react";

function PairingDisplay({ url }: { url: string }) {
  return (
    <div>
      <QRCodeSVG value={url} size={180} />
      <p>
        Or enter manually: <code>{url}</code>
      </p>
    </div>
  );
}
```

**Validate:** Display the QR code. Use any QR scanner app (phone camera, Google
Lens) to verify it decodes to the expected URL.

### Phase 3: Scanner — Camera Permission Flow

Before scanning, request camera permission. Handle three states:

```
State 1: Permission not yet requested
  → Show loading indicator or explanation text

State 2: Permission denied
  → Show explanation ("Camera access needed to scan QR codes")
  → Show "Grant Permission" button (re-triggers OS prompt)
  → Show "Go Back" navigation (don't trap the user)

State 3: Permission granted
  → Show camera with QR scanning overlay
```

**Expo/React Native example:**

```tsx
import { CameraView, useCameraPermissions } from "expo-camera";

function ScanScreen() {
  const [permission, requestPermission] = useCameraPermissions();

  if (!permission) return <Text>Requesting camera permission...</Text>;

  if (!permission.granted) {
    return (
      <View>
        <Text>Camera access is needed to scan QR codes</Text>
        <Button onPress={requestPermission} title="Grant Permission" />
        <Button onPress={goBack} title="Go Back" />
      </View>
    );
  }

  return (
    <CameraView
      style={{ flex: 1 }}
      barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
      onBarcodeScanned={handleScan}
    />
  );
}
```

**Gotcha:** Filter barcode types to `["qr"]` only. Without filtering, the
scanner will detect UPC barcodes on product packaging, books, etc. and fire
false positives.

**Validate:** Deny camera permission. Verify the fallback UI renders. Grant
permission. Verify the camera opens.

### Phase 4: Scanner — Scan Handling with Lock

This is where most implementations go wrong. The scan callback fires
continuously — you must prevent duplicate processing.

**Pattern:**

```
scannedRef = false

onScan(data):
  if scannedRef: return                     // Already processed
  if !data.startsWith(expectedScheme): return  // Not our QR
  scannedRef = true                         // Lock immediately
  connect(data)                             // Initiate connection
  navigateToConnectedScreen()               // Leave scan screen
```

**CRITICAL: Reset the lock on screen focus.** If the user navigates back to the
scan screen (e.g., after disconnecting), the lock must be cleared so they can
scan again.

**Expo/React Native example:**

```tsx
import { useFocusEffect } from "expo-router";

const scannedRef = useRef(false);

// Reset when screen regains focus
useFocusEffect(
  useCallback(() => {
    scannedRef.current = false;
  }, [])
);

const handleScan = useCallback(
  (result: { data: string }) => {
    if (scannedRef.current) return;
    const url = result.data;
    if (!url.startsWith("ws://") && !url.startsWith("wss://")) return;
    scannedRef.current = true;
    connect(url);
    router.replace("/connected");
  },
  [router]
);
```

**Validate:** Scan a QR code. Verify only one connection attempt is made (check
logs/network). Navigate back. Verify you can scan again.

### Phase 5: Scanner — Manual Connection Fallback

A simple screen with IP and port inputs:

```
┌────────────────────────────────┐
│  IP Address: [192.168.1.42  ] │
│  Port:       [9876          ] │
│                                │
│  [Connect]                     │
└────────────────────────────────┘
```

**Implementation notes:**

- Default the port to your service's standard port
- Use `decimal-pad` keyboard type for IP input (numbers + dots)
- Use `number-pad` keyboard type for port input
- Validate: host is not empty, port is a number
- Construct URL: `{scheme}://{host}:{port}`
- Call the same `connect()` function as the QR scanner

**Validate:** Enter a valid IP and port. Verify connection succeeds.

## Integration Points

### With WebSocket Sync

This recipe pairs naturally with a WebSocket live sync pattern. The QR code
encodes the WebSocket URL, and after scanning, the mobile app establishes a
persistent connection for real-time data sync. See the `live-websocket-sync`
recipe for the full sync pattern.

### With HTTP APIs

For REST API connections, encode the base URL (`http://192.168.1.42:3000`). The
mobile app stores this and uses it for all subsequent API calls.

### With Connection State

After scanning, track connection state in your app:

```
disconnected → connecting → connected → (optionally) reconnecting
```

Display status indicators so the user knows whether the pairing worked.

## Gotchas & Important Notes

- **Network isolation:** Guest WiFi networks and enterprise networks with AP
  isolation will block device-to-device communication. The QR will scan
  successfully but the connection will fail. Surface a clear error message.

- **Firewall prompts:** On macOS, the first incoming connection to your service
  will trigger a firewall dialog. On Windows, Windows Defender Firewall may
  block the port. Document which port your service uses.

- **iOS camera behavior:** On iOS, the system camera app can scan QR codes
  natively. Users may try to scan with the system camera instead of your app's
  scanner. Make it clear in the UI that they should scan within the app.

- **QR size vs. distance:** A 180px QR code is readable from about 30cm. If
  users will scan from farther away (e.g., QR on a TV/monitor across the room),
  increase the size. Rule of thumb: QR should be at least 1/10th of the scanning
  distance.

- **Dark mode QR codes:** If your generator app has a dark theme, ensure
  sufficient contrast. QR codes need a light/dark contrast ratio of at least
  4:1. Using white-on-dark-gray works; using light-gray-on-dark-gray does not.
