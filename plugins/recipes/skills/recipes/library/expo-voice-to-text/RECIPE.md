# Expo Voice-to-Text Pipeline Recipe

## Purpose

Implement a production-ready voice-to-text pipeline in an Expo React Native app.
This recipe covers the full flow: audio recording with push-to-talk and
hands-free modes, file validation, authenticated upload to a backend API that
proxies to Groq Whisper, and automatic document creation from transcribed text.

The core value is in the integration glue between Expo Audio, React Native file
handling, FormData uploads with proper MIME types, and a provider abstraction
that makes the STT backend swappable. These are the parts that aren't obvious
from reading each library's docs individually.

## When to Use

- Adding voice recording and transcription to an Expo React Native app
- Building a push-to-talk or hands-free dictation feature
- Integrating Groq Whisper (or any OpenAI-compatible STT API) with a mobile app
- Implementing a provider pattern for swappable speech-to-text backends
- Creating a voice-to-document pipeline where recordings auto-create content

## Technology Stack

| Layer          | Technology                   | Version |
| -------------- | ---------------------------- | ------- |
| Mobile Runtime | Expo SDK                     | ~54     |
| Audio          | expo-audio                   | ~1.0    |
| File System    | expo-file-system             | ~19.0   |
| Screen Wake    | expo-keep-awake              | ~15.0   |
| Animation      | react-native-reanimated      | ~3.x    |
| API Server     | Bun + Elysia                 | 1.2+    |
| STT Engine     | Groq Whisper API             | v1      |
| Auth           | BetterAuth (session cookies) | 1.4+    |

## Architecture Overview

The pipeline has four layers, with the mobile client doing recording and the API
server handling the STT provider credentials:

```
Layer 1: Recording UI (FloatingRecordButton + RecordingModal)
    |  push-to-talk (long press) or hands-free (double-tap)
    v
Layer 2: VoiceRecordingProvider (React Context)
    |  manages modal state, provider init, document creation
    v
Layer 3: STT Provider (GroqWhisperProvider implements SpeechToTextProvider)
    |  file validation, FormData upload, error mapping
    v
Layer 4: API Endpoint (POST /api/stt/transcribe)
    |  auth guard, file size validation, Groq API proxy
    v
Groq Whisper API (external)
```

### Key Design Decisions

**API-proxied transcription, not direct client calls.** The mobile app never
holds the Groq API key. All transcription goes through the backend API, which
adds the API key server-side. This means: (1) API keys are never in the mobile
bundle, (2) you can rate-limit and audit usage per user, (3) swapping STT
providers doesn't require a mobile app update.

**Provider interface for swappable backends.** The `SpeechToTextProvider`
interface lets you swap Groq for Deepgram, AssemblyAI, or a local on-device
model without changing the recording UI or context layer. The provider only
needs to implement `transcribe()` and `isAvailable()`.

**Push-to-talk AND hands-free modes from one button.** A single floating button
supports both interaction patterns: long-press (1+ seconds) activates
push-to-talk mode (release to stop), while double-tap opens hands-free mode (tap
stop button when done). This avoids cluttering the UI with two buttons.

**Context provider, not per-screen state.** Voice recording state lives in a
React Context provider so any screen can trigger recording. The context manages
the modal, provider initialization, folder context for document creation, and
navigation after transcription completes.

**Recording preset optimized for speech, not music.** 16kHz mono M4A at 64kbps
is intentionally low-fidelity. Whisper downsamples to 16kHz anyway, mono halves
file size, and 64kbps is sufficient for voice. A 10-minute recording stays under
5MB instead of 40MB+ at default quality.

## Provider Interface

The provider abstraction is the foundation. All STT backends implement this:

```typescript
interface TranscriptionResult {
  text: string;
  language?: string;
  duration?: number;
}

interface TranscribeOptions {
  language?: string; // ISO-639-1 code (e.g., 'en')
  prompt?: string; // Context hint for better accuracy
}

interface SpeechToTextProvider {
  transcribe(
    audioUri: string,
    options?: TranscribeOptions
  ): Promise<TranscriptionResult>;

  isAvailable(): Promise<boolean>;
}
```

The `audioUri` is a local file path from the recorder. The provider is
responsible for reading the file, building the upload payload, and calling the
transcription service.

## Implementation Process

### Phase 1: Recording Infrastructure

**1.1 Install dependencies**

```bash
npx expo install expo-audio expo-file-system expo-keep-awake
```

`expo-audio` is the modern replacement for `expo-av`. It provides
`useAudioRecorder` and `useAudioRecorderState` hooks for lifecycle management.

**1.2 Create the recording preset**

This is the most impactful configuration decision. Default presets record at
high quality suitable for music, which produces files 8-10x larger than needed
for speech transcription.

```typescript
// config/recording-presets.ts
import type { RecordingOptions } from "expo-audio";
import { AudioQuality } from "expo-audio";

export const SPEECH_TRANSCRIPTION_PRESET: RecordingOptions = {
  extension: ".m4a",
  sampleRate: 16000, // Matches Whisper's processing rate
  numberOfChannels: 1, // Mono - speech doesn't need stereo
  bitRate: 64000, // 64kbps - sufficient for voice
  android: {
    outputFormat: "mpeg4",
    audioEncoder: "aac",
  },
  ios: {
    outputFormat: "kAudioFormatMPEG4AAC",
    audioQuality: AudioQuality.MEDIUM,
  },
  web: {
    mimeType: "audio/mp4",
    bitsPerSecond: 64000,
  },
};
```

**Why these values:**

- **16kHz sample rate:** Groq Whisper (and OpenAI Whisper) internally downsample
  all audio to 16kHz. Recording at higher rates wastes bandwidth and storage
  with zero accuracy benefit.
- **Mono:** Speech from one person has no spatial information. Stereo doubles
  file size for no transcription improvement.
- **64kbps AAC:** At 16kHz mono, this is transparent quality for speech. A
  10-minute recording is ~5MB instead of ~40MB at default settings.
- **M4A/AAC format:** Universally supported on iOS and Android. Accepted by
  Groq, OpenAI, Deepgram, and most STT APIs. WAV would be 5-10x larger.

**1.3 Request microphone permissions**

Use `requestRecordingPermissionsAsync` from `expo-audio`. Always check before
opening the recording modal - don't start recording and then discover
permissions are denied.

```typescript
import { requestRecordingPermissionsAsync } from "expo-audio";

const { granted } = await requestRecordingPermissionsAsync();
if (!granted) {
  Alert.alert(
    "Permission Required",
    "Microphone access is required for voice recording."
  );
  return;
}
```

**Validate:** Record a short audio clip and verify the output file is M4A, mono,
and roughly 8KB/second (64kbps / 8 bits).

### Phase 2: STT Provider (Mobile Client)

**2.1 Define the provider types**

Create the `SpeechToTextProvider` interface and related types as shown in the
Provider Interface section above. Place these in
`services/speech-to-text/providers/types.ts`.

Also define recording-level types separately:

```typescript
// services/speech-to-text/types.ts
interface RecordingResult {
  uri: string; // File path to audio
  duration: number; // Duration in seconds
}

interface RecordingStatus {
  isRecording: boolean;
  duration: number;
}
```

**2.2 Implement the Groq Whisper provider**

The provider handles: file size validation, MIME type detection, FormData
construction (with React Native quirks), and authenticated upload.

```typescript
// services/speech-to-text/providers/groq-provider.ts
import { File as ExpoFile } from "expo-file-system";
import { authenticatedFetch } from "@/services/operator-api";
import type {
  SpeechToTextProvider,
  TranscribeOptions,
  TranscriptionResult,
} from "./types";

const MAX_FILE_SIZE_BYTES = 25 * 1024 * 1024; // 25 MB (Whisper limit)

export class GroqWhisperProvider implements SpeechToTextProvider {
  constructor(
    private model:
      | "whisper-large-v3-turbo"
      | "whisper-large-v3" = "whisper-large-v3-turbo"
  ) {}

  async isAvailable(): Promise<boolean> {
    return true; // API-managed, always available if authenticated
  }

  async transcribe(
    audioUri: string,
    options?: TranscribeOptions
  ): Promise<TranscriptionResult> {
    if (!audioUri) {
      throw new Error("No audio file provided");
    }

    // 1. Validate file size BEFORE uploading
    const file = new ExpoFile(audioUri);
    const fileSize = file.size;
    if (fileSize > MAX_FILE_SIZE_BYTES) {
      const fileSizeMB = fileSize / (1024 * 1024);
      throw new Error(
        `Recording is too large (${fileSizeMB.toFixed(1)} MB). ` +
          `Please keep recordings under 2 minutes.`
      );
    }

    // 2. Determine MIME type from extension
    const ext = audioUri.split(".").pop()?.toLowerCase();
    const mimeType = MIME_TYPES[ext || "m4a"] || "audio/mp4";
    const fileName = `recording.${ext || "m4a"}`;

    // 3. Build FormData (React Native quirk: pass object, not Blob)
    const formData = new FormData();
    formData.append("file", {
      uri: file.uri,
      type: mimeType,
      name: fileName,
    } as unknown as Blob);
    formData.append("model", this.model);

    if (options?.language) {
      formData.append("language", options.language);
    }

    // 4. Upload with auth
    const response = await authenticatedFetch("/api/stt/transcribe", {
      method: "POST",
      body: formData,
      // DO NOT set Content-Type header - fetch sets it with boundary
    });

    if (!response.ok) {
      throw await this.mapErrorResponse(response);
    }

    const data = await response.json();
    return { text: data.text, language: data.language };
  }
}

const MIME_TYPES: Record<string, string> = {
  m4a: "audio/mp4",
  wav: "audio/wav",
  flac: "audio/flac",
  mp3: "audio/mpeg",
};
```

**Critical gotcha: FormData file append in React Native.** You cannot use a
standard `Blob` or `File` object. React Native's `FormData` expects a plain
object with `{ uri, type, name }` properties. The `as unknown as Blob` cast is
intentional - it satisfies TypeScript while React Native's fetch implementation
handles the object correctly. If you try to use an actual Blob, the upload will
send an empty or corrupted file.

**Critical gotcha: Do NOT set Content-Type header.** When sending FormData,
`fetch()` automatically sets `Content-Type: multipart/form-data` with the
correct boundary string. If you manually set the Content-Type header, the
boundary will be missing and the server will fail to parse the multipart body.

**2.3 Map error responses to user-friendly messages**

Map HTTP status codes to actionable error messages:

| Status | Error Message                              |
| ------ | ------------------------------------------ |
| 401    | Authentication required. Please sign in.   |
| 413    | Recording too large. Keep under 2 minutes. |
| 429    | Rate limit exceeded. Try again later.      |
| 503    | Service unavailable. Try again later.      |
| 5xx    | Service error. Try a shorter recording.    |

Also catch `TypeError` with "network" in the message for offline errors.

**Validate:** Call `provider.transcribe(uri)` with a test recording and verify
you get text back. Test with a file over 25MB to verify the size check works.

### Phase 3: API Endpoint

**3.1 Create STT feature module on the server**

The API endpoint proxies transcription requests to Groq, keeping the API key
server-side.

```
src/features/stt/
  constants.ts   # API URLs, model enum, file size limit
  types.ts       # TranscribeParams, TranscriptionResult, GroqResponse
  service.ts     # STTService class
  index.ts       # Re-exports

src/routes/stt/
  transcribe.ts  # Elysia route handler
  index.ts       # Route group
```

**3.2 Define constants**

```typescript
// features/stt/constants.ts
export const GROQ_API_BASE_URL = "https://api.groq.com/openai/v1";
export const GROQ_TRANSCRIPTION_ENDPOINT = "/audio/transcriptions";

export enum GroqWhisperModel {
  LARGE_V3 = "whisper-large-v3",
  LARGE_V3_TURBO = "whisper-large-v3-turbo",
}

export const DEFAULT_MODEL = GroqWhisperModel.LARGE_V3_TURBO;
export const MAX_AUDIO_FILE_SIZE_BYTES = 25 * 1024 * 1024; // 25 MB
```

**3.3 Implement the STT service**

The service validates the file, builds the Groq API request, and maps errors:

```typescript
// features/stt/service.ts
export class STTService {
  isConfigured(): boolean {
    return Boolean(env.GROQ_API_KEY);
  }

  async transcribe(params: TranscribeParams): Promise<TranscriptionResult> {
    if (!env.GROQ_API_KEY) {
      throw APIError.unavailable("STT is not configured on this server");
    }

    // Validate file size server-side too (defense in depth)
    if (params.audio.size > MAX_AUDIO_FILE_SIZE_BYTES) {
      throw APIError.invalidArgument(
        `Audio file too large. Maximum is ${MAX_AUDIO_FILE_SIZE_BYTES / 1024 / 1024}MB`
      );
    }

    const formData = new FormData();
    formData.append("file", params.audio);
    formData.append("model", params.model || DEFAULT_MODEL);
    formData.append("response_format", "verbose_json");

    if (params.language) formData.append("language", params.language);

    const response = await fetch(
      `${GROQ_API_BASE_URL}${GROQ_TRANSCRIPTION_ENDPOINT}`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${env.GROQ_API_KEY}` },
        body: formData,
      }
    );

    if (!response.ok) {
      // Map Groq errors to APIError codes (401->unavailable, 429->resourceExhausted, etc.)
      throw this.mapGroqError(response);
    }

    const data = await response.json();
    return {
      text: data.text,
      duration: data.duration,
      language: data.language,
    };
  }
}

export const sttService = new STTService();
```

**3.4 Create the Elysia route**

```typescript
// routes/stt/transcribe.ts
import { Elysia, t } from "elysia";
import { requireAuth } from "@core/http";
import { sttService } from "@features/stt";

export const sttTranscribeRoute = new Elysia({ prefix: "/stt" })
  .use(requireAuth)
  .post(
    "/transcribe",
    async ({ body, set }) => {
      const result = await sttService.transcribe({
        audio: body.file,
        model: body.model,
        language: body.language,
      });
      return {
        text: result.text,
        duration: result.duration,
        language: result.language,
      };
    },
    {
      body: t.Object({
        file: t.File(),
        model: t.Optional(t.String()),
        language: t.Optional(t.String()),
      }),
    }
  );
```

**Important:** The route uses `requireAuth` middleware. The mobile client must
send session cookies with the request. In this project, `authenticatedFetch`
handles this by extracting cookies from the BetterAuth client.

**3.5 Add environment variable**

Add `GROQ_API_KEY` to your environment config and `.env` file. The service's
`isConfigured()` check prevents crashes if the key is missing - it returns a 503
instead.

**Validate:** Use curl to test the endpoint with a sample audio file:

```bash
curl -X POST http://localhost:3000/api/stt/transcribe \
  -H "Cookie: <session-cookie>" \
  -F "file=@test-recording.m4a" \
  -F "model=whisper-large-v3-turbo"
```

### Phase 4: Recording UI Components

**4.1 RecordingModal - the recording/transcription flow**

The modal manages a state machine with four states:

```
idle -> recording -> transcribing -> (complete, closes modal)
                  -> error -> (retry or cancel)
```

Key behaviors:

- **Auto-starts recording** when modal becomes visible. No separate "start"
  button - opening the modal IS starting the recording.
- **Auto-stops at 10 minutes** to prevent accidental mega-recordings.
- **Shows estimated file size** during recording (calculated from bitrate and
  duration) so users know if they're approaching the 25MB limit.
- **Cleans up audio files** after successful transcription. Failed
  transcriptions leave the file for retry.
- **Supports external stop trigger** via `shouldStop` prop for push-to-talk
  mode.
- **Keeps screen awake** during recording with `expo-keep-awake`.

```typescript
// Simplified component structure
function RecordingModal({
  visible,
  onClose,
  onTranscriptionComplete,
  onTranscribe,
  pushToTalkMode = false,
  shouldStop = false,
}: RecordingModalProps) {
  const recorder = useAudioRecorder(SPEECH_TRANSCRIPTION_PRESET);
  const recorderState = useAudioRecorderState(recorder);
  const [state, setState] = useState<
    "idle" | "recording" | "transcribing" | "error"
  >("idle");

  // Auto-start when visible
  useEffect(() => {
    if (visible && state === "idle") startRecording();
  }, [visible]);

  // Auto-stop at 10 minutes
  useEffect(() => {
    if (state === "recording" && recorderState.durationMillis >= 600000) {
      stopRecording();
    }
  }, [recorderState.durationMillis]);

  // External stop trigger (push-to-talk)
  useEffect(() => {
    if (pushToTalkMode && shouldStop && state === "recording") {
      if (recorderState.isRecording && recorderState.durationMillis > 0) {
        stopRecording();
      }
    }
  }, [shouldStop]);

  async function startRecording() {
    setState("recording");
    await setAudioModeAsync({ allowsRecording: true, playsInSilentMode: true });
    await recorder.prepareToRecordAsync();
    recorder.record();
  }

  async function stopRecording() {
    await recorder.stop();
    // Verify URI exists and file has content
    setState("transcribing");
    const text = await onTranscribe(recorder.uri);
    onTranscriptionComplete(text);
  }

  // Render: recording state shows mic icon + timer + stop button
  //         transcribing state shows spinner
  //         error state shows message + retry/cancel buttons
}
```

**Gotcha: Check `recorderState.isRecording` before stopping.** In push-to-talk
mode, the stop signal can arrive before the recorder has fully initialized. If
you call `recorder.stop()` while it's still preparing, you'll get an error. Add
a small delay retry if the recorder isn't ready yet.

**Gotcha: Set audio mode BEFORE preparing the recorder.** Call
`setAudioModeAsync({ allowsRecording: true })` before
`recorder.prepareToRecordAsync()`. If you skip this, iOS may silently fail to
record (you'll get a 0-byte file).

**Gotcha: Reset state before closing.** Set state back to `idle` before calling
`onClose()`. If you don't, reopening the modal will find it in a stale state and
the auto-start effect won't fire.

**4.2 FloatingRecordButton - the interaction trigger**

A single floating action button that supports two recording modes:

- **Long press (1+ seconds):** Push-to-talk mode. Recording starts after the
  hold threshold. Release finger to stop and transcribe.
- **Double-tap:** Hands-free mode. Recording starts immediately. User taps a
  stop button in the modal when done.

```typescript
// Interaction logic (simplified)
function handlePressIn() {
  const now = Date.now();
  if (now - lastTapTime < DOUBLE_TAP_DELAY) {
    // Double-tap -> hands-free mode
    checkPermissionsAndOpenModal(false);
    return;
  }
  setLastTapTime(now);
  // Start 1-second timer for push-to-talk
  const timer = setTimeout(() => {
    checkPermissionsAndOpenModal(true); // push-to-talk mode
  }, 1000);
  setPressTimer(timer);
}

function handlePressOut() {
  if (pressTimer) clearTimeout(pressTimer);
  if (isRecordingActive) {
    setShouldStopRecording(true); // trigger stop in modal
  }
}
```

**Design choice: 1-second hold threshold.** This prevents accidental recordings
from taps. The button shows an animated progress ring during the hold to provide
visual feedback. If released before 1 second, nothing happens (unless it's the
second tap of a double-tap).

**Validate:** Test both interaction modes. Verify that: (1) single quick taps do
nothing, (2) double-tap opens hands-free recording, (3) long-press opens
push-to-talk and releasing stops recording.

### Phase 5: Voice Recording Context Provider

**5.1 Create the VoiceRecordingProvider**

This React Context is the orchestration layer. It owns: the STT provider
instance, the current folder context (for document creation), the recording
modal, and post-transcription logic.

```typescript
// context/voice-recording.tsx
interface VoiceRecordingContextType {
  groqProvider: GroqWhisperProvider | null;
  currentProjectId: string | null;
  currentGroupId: string | null;
  setCurrentContext: (projectId: string, groupId?: string) => void;
  startHandsFreeRecording: () => Promise<void>;
  startPushToTalkRecording: () => Promise<void>;
  stopPushToTalkRecording: () => void;
  refreshGroqProvider: () => Promise<void>;
}
```

Key responsibilities:

1. **Provider initialization:** Creates the `GroqWhisperProvider` on mount,
   reading the user's preferred Whisper model from settings. Exposes
   `refreshGroqProvider` for when the user changes the model in settings.

2. **Permission handling:** Checks microphone permissions before opening the
   modal. Keeps permission logic out of the recording components.

3. **Folder context tracking:** Screens call
   `setCurrentContext(projectId, groupId)` so the provider knows WHERE to create
   documents. Without this, voice recordings would have no folder assignment.

4. **Document creation after transcription:** The `onTranscriptionComplete`
   callback creates a new document with the transcribed text, assigns it to the
   current group, and navigates to the new document.

5. **Post-transcription triggers:** After document creation, fires a
   `transcription_complete` event that can trigger automated pipelines (e.g.,
   AI-powered formatting, title generation, tagging).

```typescript
// Document creation flow (inside the provider)
const handleDocumentCreated = useCallback(
  async (transcription: string) => {
    const db = getDatabase();
    const document = await documentService.create(
      db,
      transcription,
      currentProjectId,
      user.id
    );

    if (currentGroupId) {
      await groupService.addDocument(db, currentGroupId, document.id);
    }

    // Fire trigger for post-processing pipelines
    await executionEngine.fireTrigger(
      { event: "transcription_complete" },
      { id: document.id, title: document.title, projectId: currentProjectId }
    );

    // Navigate to the new document
    router.push(`/document/${document.id}`);
  },
  [user, currentProjectId, currentGroupId, router]
);
```

**5.2 Mount the provider in the app layout**

Wrap your app (or the authenticated portion) with `VoiceRecordingProvider`. The
provider renders the `RecordingModal` internally - consuming components don't
need to render it.

```typescript
// app/_layout.tsx (simplified)
<VoiceRecordingProvider>
  {children}
</VoiceRecordingProvider>
```

**5.3 Consume from any screen**

Any component can trigger recording via the context hook:

```typescript
const {
  startHandsFreeRecording,
  startPushToTalkRecording,
  stopPushToTalkRecording,
  setCurrentContext,
} = useVoiceRecording();

// Tell the provider which folder we're in
useEffect(() => {
  setCurrentContext(projectId, groupId);
}, [projectId, groupId]);
```

**Validate:** Trigger a recording from two different screens and verify that
documents are created in the correct folder each time.

## Integration Points

### Triggering Recording from the App

The `VoiceRecordingProvider` exposes three methods: `startHandsFreeRecording`,
`startPushToTalkRecording`, and `stopPushToTalkRecording`. Any component can
call these. Common integration points:

- **Floating action button** on the document list screen
- **Toolbar button** inside the document editor (appends transcription to
  existing document instead of creating new)
- **Tab bar button** for app-wide access
- **Keyboard shortcut** on physical keyboards

### Post-Transcription Automation

After document creation, the provider fires a `transcription_complete` trigger.
This is an integration point for automated pipelines:

- Auto-generate document title from content
- Apply AI formatting (markdown structure, paragraphs)
- Run content tagging or categorization
- Trigger sync to cloud

### Settings Integration

Expose a settings screen for:

| Setting       | Type   | Default                | Purpose                              |
| ------------- | ------ | ---------------------- | ------------------------------------ |
| Whisper Model | enum   | whisper-large-v3-turbo | Accuracy vs speed tradeoff           |
| Language Hint | string | (none, auto-detect)    | Improves accuracy for known language |

When the user changes the Whisper model in settings, call
`refreshGroqProvider()` from the context to reinitialize the provider.

### Adding a New STT Provider

To add a new provider (e.g., Deepgram, local Whisper):

1. Create a class implementing `SpeechToTextProvider`
2. Implement `transcribe(audioUri)` and `isAvailable()`
3. Update the context to instantiate the new provider based on settings
4. If the provider calls a different API endpoint, add the route server-side

No changes needed to the recording UI, modal, or button components.

## Gotchas & Important Notes

- **React Native FormData is NOT standard FormData.** You must pass
  `{ uri, type, name }` objects, not Blob instances. This is the single most
  common source of "upload sends empty file" bugs. The `as unknown as Blob` cast
  is the standard workaround.

- **Never set Content-Type header on FormData requests.** Let `fetch()` set it
  automatically with the multipart boundary. Setting it manually breaks the
  upload.

- **Validate file size on both client AND server.** The client check gives a
  fast user-facing error. The server check is defense-in-depth against modified
  clients. Whisper's hard limit is 25MB.

- **M4A MIME type is `audio/mp4`, not `audio/m4a`.** There is no registered
  `audio/m4a` MIME type. M4A is an MPEG-4 container, so the correct type is
  `audio/mp4`. Using the wrong MIME type may cause the Groq API to reject the
  file.

- **Call `setAudioModeAsync` before recording.** On iOS, if you don't set
  `allowsRecording: true`, the recorder may silently produce empty files. This
  must happen before `prepareToRecordAsync()`.

- **Check `recorderState.isRecording` before `recorder.stop()`.** Calling stop
  on a recorder that hasn't fully started throws an error. In push-to-talk mode,
  the user can release their finger before the recorder is ready. Add a 500ms
  retry with a timeout.

- **Clean up audio files after transcription.** Recordings are stored in the
  app's cache directory. If you don't delete them, they accumulate. Delete after
  successful transcription; leave on failure so the user can retry.

- **Use `expo-keep-awake` during recording.** Without it, the screen may dim or
  lock during a long recording, which can interrupt the audio capture.

- **Auto-stop at a reasonable limit.** 10 minutes prevents accidental
  mega-recordings that would exceed the 25MB file size limit or result in very
  long transcription times. At 64kbps, 10 minutes is approximately 4.7MB.

- **Reset modal state before closing.** If you close the modal without resetting
  state to `idle`, reopening it won't trigger the auto-start effect because the
  `useEffect` dependency hasn't changed.

- **The `whisper-large-v3-turbo` model is faster but slightly less accurate than
  `whisper-large-v3`.** Default to turbo for real-time use. Offer the full model
  as a setting for users who prioritize accuracy over speed.

- **Platform.OS === 'web' needs special handling.** The Web Audio API works
  differently. If you need web support, the recording preset's `web` config uses
  `MediaRecorder` under the hood, but FormData upload works the same way. The
  floating button component should be hidden or adapted for web.
