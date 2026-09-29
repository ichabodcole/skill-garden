# Live WebSocket Sync Recipe

## Purpose

Implement real-time unidirectional data sync from a host application to one or
more connected client apps over WebSocket. The host is the source of truth —
when its state changes, updates are pushed to all connected clients
automatically.

This recipe captures the full sync pipeline: WebSocket server management, store
change subscriptions with debouncing, a two-tier message protocol (full sync +
incremental updates), new client detection with immediate state push, and client
reconnection with exponential backoff. These are the integration patterns that
require careful coordination and aren't obvious from any single library's docs.

This recipe is **technology-agnostic at the architecture level** — the patterns
work with any WebSocket library, state management system, and serialization
format. Implementation examples reference Tauri/Rust + React (host) and
Expo/React Native (client).

**Prerequisite:** For device discovery via QR code scanning, see the
`qr-code-local-pairing` recipe.

## When to Use

- A host app needs to push state changes to connected viewers in real time
- You want parameter tweaks on the host to appear on clients within ~250ms
- The host is the single source of truth (no conflict resolution needed)
- Clients should automatically reconnect when the connection drops
- One host broadcasting to one or more clients

## Architecture Overview

### Mental Model

```
┌─────────────────────────┐           ┌──────────────────────────┐
│        Host App         │           │      Client App(s)       │
│                         │           │                          │
│  State Stores           │           │  WebSocket Client        │
│    ↓ subscribe          │    WS     │    ↓ on message          │
│  Change Detection       │ ───────>  │  Message Router          │
│    ↓ debounce (250ms)   │           │    ↓ by type             │
│  JSON Serialization     │           │  Validate & Apply        │
│    ↓ broadcast          │           │    ↓                     │
│  WebSocket Server       │           │  State Stores            │
│                         │           │                          │
│  Poll: new clients?     │           │  Reconnect: exp backoff  │
│    ↓ yes → full push    │           │    ↓ 2s → 3s → 4.5s ... │
└─────────────────────────┘           └──────────────────────────┘
```

The host subscribes to its own state stores. When state changes, it debounces
and broadcasts a JSON message over WebSocket. Clients receive, validate, and
apply the update to their own stores.

### Key Design Decisions

**Unidirectional sync (host → clients).** The host is the source of truth.
Clients are viewers/consumers. This is intentionally simple — no conflict
resolution, no operational transforms, no CRDTs. If you need bidirectional sync,
this recipe is not the right starting point (consider Yjs, Automerge, or
PowerSync instead).

**Two-tier message protocol.** Two message types serve different purposes:

1. **Full sync (`session_update`)** — complete state snapshot. Sent when a new
   client connects or when major structural changes happen (new data loaded, new
   session). The client replaces all its state.

2. **Incremental update (`config_update`)** — partial parameter changes. Sent
   when individual settings change (sliders, toggles). The client merges into
   existing state without rebuilding.

This split matters for user experience. Full syncs are expensive — they may
cause the client to rebuild rendering scenes, reset animations, or flash.
Incremental updates let the client apply changes smoothly while maintaining
continuity (e.g., animation keeps playing, no flicker).

**Debounce, don't throttle.** When the user drags a slider, it produces dozens
of change events per second. Debouncing waits for a pause (250ms) before
sending, which means the client gets the final value after the drag ends — not a
flood of intermediate values. 250ms feels responsive while avoiding flood.

**New client detection with immediate push.** When a new client connects, it has
no state. It needs a full sync immediately — it shouldn't have to wait for the
next state change. Poll the client count (or use connection events) and push the
current state when a new client appears.

### Trade-offs

- **Polling for new clients** adds up to 2 seconds of latency before a new
  client receives data. Event-driven client detection is instant but requires
  more server wiring. Start with polling; optimize later if needed.
- **No guaranteed delivery.** WebSocket messages can be lost during disconnects.
  Full syncs on reconnection compensate — the client always gets a complete
  snapshot after reconnecting.
- **JSON serialization** is human-readable and debuggable but adds overhead for
  large payloads. If your state exceeds ~100KB regularly, consider MessagePack
  or Protocol Buffers.
- **No backpressure.** If a client can't keep up with the message rate, messages
  queue (or drop, depending on the broadcast implementation). For most UI sync
  use cases with debouncing, this isn't an issue.

## Data Model

### Message Envelope

All messages use a typed envelope:

```json
{
  "type": "session_update | config_update",
  "payload": { ... }
}
```

The `type` field routes messages to handlers. The `payload` varies by type.

### Full Sync Payload

Contains everything the client needs to render from scratch:

```json
{
  "type": "session_update",
  "payload": {
    "name": "Session Name",
    "data": { ... },
    "config": { ... },
    "metadata": { ... }
  }
}
```

Include all state the client needs. The client will replace its entire local
state with this payload.

### Incremental Update Payload

Contains only the changed fields:

```json
{
  "type": "config_update",
  "payload": {
    "speed": 1.5,
    "mode": "wave"
  }
}
```

Only changed fields are included. The client merges these into its existing
config.

## Service Layer / Core API

### Host: WebSocket Server

The server needs four operations:

| Operation            | Purpose                                          |
| -------------------- | ------------------------------------------------ |
| `start(port)`        | Bind to `0.0.0.0:{port}`, accept connections     |
| `stop()`             | Close all connections, release port              |
| `broadcast(message)` | Send string to all connected clients             |
| `getStatus()`        | Return `{ running, port, localIp, clientCount }` |

**Broadcast pattern:** Use a pub/sub or broadcast channel. Each client gets its
own receive task that reads from the shared channel. The server ignores incoming
client messages (unidirectional).

**Client lifecycle:**

```
accept connection
  → increment client count
  → subscribe to broadcast channel
  → forward broadcast messages to this client's WebSocket
  → on disconnect: unsubscribe, decrement client count
```

### Host: Store Subscription & Debounce

```
DEBOUNCE_MS = 250
timer = null

subscribe(stores, onChange):
  for store in stores:
    store.onChange((current, previous) =>
      if relevantFieldsChanged(current, previous):
        clearTimeout(timer)
        timer = setTimeout(pushSync, DEBOUNCE_MS)
    )

pushSync():
  state = readAllStores()
  message = serialize({ type: "session_update", payload: state })
  server.broadcast(message)
```

**Be selective about which store fields trigger a sync.** Don't subscribe to
UI-only state (window size, panel visibility, cursor position). Only sync state
that the client needs to render.

### Host: New Client Detection

```
lastClientCount = 0

pollClientCount():
  every 2 seconds:
    count = server.getStatus().clientCount
    if count > lastClientCount:
      pushSync()               // New client needs full state
    lastClientCount = count
```

**Why `count > last` instead of `count > 0 && last === 0`:** The simpler check
misses the case where client count goes from 1 → 2. The second client would
never receive an initial push.

### Client: Connection State Machine

```
States: disconnected → connecting → connected
                                  ↘ reconnecting → connected
                                                 ↘ reconnecting (retry)

Transitions:
  connect(url):      disconnected → connecting
  onOpen:            connecting → connected
  onClose(accidental): connected → reconnecting
  onClose(intentional): connected → disconnected
  onReconnectSuccess: reconnecting → connected
```

Track state in a store so the UI can display connection status.

### Client: Reconnection with Exponential Backoff

```
INITIAL_DELAY = 2000      // 2 seconds
MAX_DELAY = 15000          // 15 seconds
BACKOFF_FACTOR = 1.5

intentionalClose = false

onClose():
  if intentionalClose: return     // User disconnected, don't retry
  delay = INITIAL_DELAY
  while not connected:
    wait(delay)
    attemptConnection()
    delay = min(delay * BACKOFF_FACTOR, MAX_DELAY)
```

**CRITICAL: Track `intentionalClose`.** Without this flag, calling
`disconnect()` triggers auto-reconnect, which immediately undoes the disconnect.
Set the flag before closing the socket; clear it when initiating a new
connection.

### Client: Message Handling

```
onMessage(raw):
  if typeof raw !== "string": return     // Binary messages ignored
  envelope = JSON.parse(raw)             // Parse errors → return silently

  switch envelope.type:
    "session_update":
      validatePayload(envelope.payload)
      replaceAllState(envelope.payload)

    "config_update":
      whitelistAndTypeCheck(envelope.payload)
      mergeIntoConfig(envelope.payload)
```

**Whitelist incremental update fields.** Don't blindly merge arbitrary keys into
your state. Maintain an explicit map of known fields and their expected types:

```
KNOWN_FIELDS = {
  "speed": "number",
  "mode": "string",
  "enabled": "boolean",
  "amplitude": "number",
}

validate(payload):
  result = {}
  for key, expectedType in KNOWN_FIELDS:
    if key in payload and typeof payload[key] === expectedType:
      result[key] = payload[key]
  return result
```

This prevents the host from accidentally overwriting client-local state and
provides basic type safety.

## Implementation Process

### Phase 1: WebSocket Server (Host)

Set up a WebSocket server that accepts connections and broadcasts messages.

**Rust (Tokio + tokio-tungstenite):**

```rust
use tokio::sync::broadcast;
use tokio::net::TcpListener;
use tokio_tungstenite::accept_async;

// Broadcast channel — all clients receive the same messages
let (tx, _) = broadcast::channel::<String>(64);

// Accept loop
let listener = TcpListener::bind("0.0.0.0:9876").await?;
loop {
    let (stream, _) = listener.accept().await?;
    let rx = tx.subscribe();
    tokio::spawn(handle_client(stream, rx, client_count.clone()));
}

// Broadcast to all clients
tx.send(message_string).unwrap_or(0);
```

**Node.js (ws library):**

```javascript
import { WebSocketServer } from "ws";

const wss = new WebSocketServer({ port: 9876 });

wss.on("connection", (ws) => {
  // Track client, push initial state
});

function broadcast(message) {
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(message);
    }
  }
}
```

**Python (websockets):**

```python
import websockets

clients = set()

async def handler(websocket):
    clients.add(websocket)
    try:
        async for _ in websocket:
            pass  # Ignore client messages
    finally:
        clients.discard(websocket)

def broadcast(message):
    websockets.broadcast(clients, message)
```

**Validate:** Start the server. Connect with a WebSocket client tool (e.g.,
`wscat -c ws://localhost:9876`). Send a broadcast. Verify it arrives.

### Phase 2: Store Subscriptions with Debounce (Host)

Wire your state stores to trigger debounced broadcasts.

**Pattern (React + Zustand):**

```typescript
const DEBOUNCE_MS = 250;
const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

// Read current state and broadcast
const pushSync = useCallback(() => {
  const appState = useAppStore.getState();
  const message = JSON.stringify({
    type: "session_update",
    payload: buildPayload(appState),
  });
  server.broadcast(message);
}, []);

// Debounced trigger
const debouncedPush = useCallback(() => {
  if (debounceRef.current) clearTimeout(debounceRef.current);
  debounceRef.current = setTimeout(pushSync, DEBOUNCE_MS);
}, [pushSync]);

// Subscribe to relevant store changes
useEffect(() => {
  const unsub = useAppStore.subscribe((curr, prev) => {
    if (curr.data !== prev.data || curr.config !== prev.config) {
      debouncedPush();
    }
  });
  return unsub;
}, [debouncedPush]);
```

**Key detail: `useRef` for active state.** Use a ref (not React state) to track
whether sync is active. Store subscriptions access it synchronously via
`.getState()`, which avoids stale closure issues.

**Validate:** Change a state value on the host. Verify the connected client
receives a message within ~300ms.

### Phase 3: New Client Detection (Host)

Push full state when a new client connects.

```typescript
const lastCountRef = useRef(0);

useEffect(() => {
  const interval = setInterval(async () => {
    const status = server.getStatus();
    if (status.clients > lastCountRef.current) {
      pushSync(); // New client needs everything
    }
    lastCountRef.current = status.clients;
  }, 2000);

  return () => clearInterval(interval);
}, [pushSync]);
```

**Validate:** Start the host with state loaded. Connect a new client. Verify it
receives a full sync within 2 seconds. Connect a second client. Verify it also
receives a full sync.

### Phase 4: WebSocket Client with Reconnection (Client)

Build the client connection manager with automatic reconnection.

**Pattern:**

```typescript
let ws: WebSocket | null = null;
let reconnectDelay = 2000;
let intentionalClose = false;

function connect(url: string) {
  disconnect();
  intentionalClose = false;
  reconnectDelay = 2000;

  ws = new WebSocket(url);

  ws.onopen = () => {
    reconnectDelay = 2000; // Reset backoff on success
    setStatus("connected");
  };

  ws.onmessage = (event) => {
    if (typeof event.data !== "string") return;
    handleMessage(event.data);
  };

  ws.onclose = () => {
    ws = null;
    if (!intentionalClose) {
      setStatus("reconnecting");
      setTimeout(() => {
        connect(url); // Retry
        reconnectDelay = Math.min(reconnectDelay * 1.5, 15000);
      }, reconnectDelay);
    }
  };
}

function disconnect() {
  intentionalClose = true;
  ws?.close();
  ws = null;
}
```

**Gotcha: `typeof event.data` guard.** WebSocket `event.data` can be `string`,
`ArrayBuffer`, or `Blob`. Always check before parsing as JSON.

**Validate:** Connect to the host. Kill the host server. Verify the client
attempts reconnection with increasing delays. Restart the host. Verify the
client reconnects and receives a full sync.

### Phase 5: Message Routing and State Application (Client)

Route messages by type and apply to local state.

```typescript
function handleMessage(raw: string) {
  let envelope: { type: string; payload: unknown };
  try {
    envelope = JSON.parse(raw);
  } catch {
    return; // Silently ignore malformed messages
  }

  switch (envelope.type) {
    case "session_update":
      handleFullSync(envelope.payload);
      break;
    case "config_update":
      handleIncremental(envelope.payload);
      break;
  }
}

function handleFullSync(payload: unknown) {
  if (!payload || typeof payload !== "object") return;
  // Validate structure, then load into state store
  appStore.loadFromSync(payload);
}

function handleIncremental(payload: unknown) {
  if (!payload || typeof payload !== "object") return;
  if (!appStore.isLoaded()) return; // Ignore if no session loaded

  const validated = whitelistFields(payload);
  if (Object.keys(validated).length > 0) {
    appStore.mergeConfig(validated);
  }
}
```

**Validate:** Send a full sync from the host. Verify the client renders the
complete state. Change a parameter on the host. Verify the client updates
smoothly without rebuilding.

## Integration Points

### With QR Code Pairing

Use the `qr-code-local-pairing` recipe for device discovery. The QR code encodes
the WebSocket URL. After scanning, the client connects and begins receiving
state updates.

### With App Lifecycle (Mobile)

On mobile, the OS may kill WebSocket connections when the app is backgrounded.
Listen for app state changes and manage the connection:

```
onAppForeground: reconnect if was connected
onAppBackground: optionally pause (OS may kill anyway)
```

### With Connection State UI

Display connection status to the user:

- **Connected** (green) — live updates flowing
- **Reconnecting** (yellow) — connection lost, retrying
- **Disconnected** (hidden or gray) — not connected

On the host, show the client count: "1 device connected" or "2 devices
connected".

## Settings / Configuration

| Setting                    | Type   | Default | Purpose                                           |
| -------------------------- | ------ | ------- | ------------------------------------------------- |
| Debounce interval          | ms     | 250     | How long to wait after last change before sending |
| Server port                | number | 9876    | WebSocket server port                             |
| Reconnect initial delay    | ms     | 2000    | First reconnect attempt delay                     |
| Reconnect max delay        | ms     | 15000   | Maximum backoff delay                             |
| Backoff factor             | float  | 1.5     | Multiplier for exponential backoff                |
| Broadcast channel capacity | number | 64      | Ring buffer size (Rust broadcast)                 |
| Client poll interval       | ms     | 2000    | How often to check for new clients                |

## Adapting to Different Tech Stacks

### WebSocket Server

| Platform | Recommended Library                            | Notes                   |
| -------- | ---------------------------------------------- | ----------------------- |
| Rust     | `tokio-tungstenite` + `tokio::sync::broadcast` | Async, high performance |
| Node.js  | `ws`                                           | Simple, widely used     |
| Python   | `websockets`                                   | Asyncio-based           |
| Go       | `gorilla/websocket`                            | Standard choice         |
| Deno     | Built-in `Deno.serve` + `WebSocket`            | No dependency needed    |

### State Management

The subscription + debounce pattern works with any reactive state system:

- **Zustand** (React): `.subscribe((curr, prev) => ...)`
- **Pinia** (Vue): `store.$subscribe((mutation, state) => ...)`
- **Svelte stores**: `store.subscribe(value => ...)`
- **RxJS**: `.pipe(debounceTime(250))` (built-in debounce)
- **Redux**: `store.subscribe(() => ...)` with manual change detection

### Serialization

JSON is the default. Consider alternatives for specific needs:

| Format           | When to Use                                    |
| ---------------- | ---------------------------------------------- |
| JSON             | Default. Human-readable, universally supported |
| MessagePack      | Payloads > 100KB. ~30% smaller than JSON       |
| Protocol Buffers | Strong typing needed. Schema evolution         |
| CBOR             | Binary data mixed with structured data         |

## Gotchas & Important Notes

- **Broadcast channel capacity (Rust).** `tokio::sync::broadcast` uses a ring
  buffer. If a slow client falls behind by more than the buffer capacity, it
  gets `RecvError::Lagged` and misses messages. This is fine for this pattern —
  the next full sync corrects it. But don't set capacity too low (< 16).

- **Parse errors should be silent.** Don't crash the client on malformed
  messages. Log them in development, ignore them in production. Network
  corruption, partial messages during disconnect, and protocol version
  mismatches all produce parse errors.

- **`useRef` vs `useState` for active tracking.** React state causes re-renders.
  Use `useRef` for values accessed inside timers and store subscriptions. Use
  state only for values the UI needs to display.

- **Cleanup on unmount/close.** Always clear debounce timers, stop polling
  intervals, close WebSocket connections, and stop the server when the host
  component unmounts. Leaked timers cause ghost messages after the UI is gone.

- **Module-level singleton for client.** The WebSocket client should use
  module-level state (not React state) so the connection persists across screen
  navigations. Putting it in a component's state means it dies when the
  component unmounts.

- **Full sync on reconnection is essential.** After a reconnect, the client
  missed all messages during the disconnect. It must receive a complete state
  snapshot. The host's new-client detection handles this automatically if the
  client count goes up when the client reconnects.

- **Firewall and port.** Bind to `0.0.0.0` (all interfaces), not `127.0.0.1`
  (localhost only). The latter is unreachable from other devices on the network.
