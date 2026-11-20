# Spec: NotchAI — native macOS Dynamic Island AI assistant

Status: approved for implementation by the user's explicit instruction ("Start implementing the
project. Do not stop at planning."). This spec is the living source of truth; it is updated when
decisions change.

## Objective
A real, installable, native macOS agent application (Swift/SwiftUI/AppKit) that runs quietly as a
background menu-bar/dynamic-island utility. The island wraps the MacBook camera notch (and works on
notchless/external displays), expands into AI chat + a mini browser, and captures the full selected
display while excluding the island overlay so screenshots show what is behind it.

Target machine: MacBook Air, Apple Silicon, macOS 27.0 (build 26A5416b), Xcode 27.2, Swift 6.4.2.
Deployment target: macOS 15.0 (API floor needed: `SCScreenshotManager`, SwiftUI `onHover`,
`SMAppService`); runs on the installed macOS 27.

## Tech stack (no third-party dependencies)
Swift 6.4 compiler in Swift 5 language mode, SwiftUI, AppKit (`NSPanel`, `NSStatusItem`,
`NSWindowController`), ScreenCaptureKit (`SCScreenshotManager`, `SCContentFilter`, `SCShareableContent`),
WebKit (`WKWebView`), URLSession streaming (SSE), Security (`SecItem` Keychain), ServiceManagement
(`SMAppService`), Carbon hot keys (`RegisterEventHotKey`), Codable JSON persistence under
`~/Library/Application Support/NotchAI/`. SwiftPM executable target assembled into a signed `.app`.

## Commands
- Build (debug):  `swift build`
- Build (release):`swift build -c release`
- Tests:          `swift test`
- App bundle:     `./scripts/build-app.sh` → `build/NotchAI.app`
- Run:            `open ~/Applications/NotchAI.app`  (agent app: menu-bar item + island, no Dock icon by default)

## Project structure
```
NotchAI/
  Package.swift                 SwiftPM manifest (executable + test target)
  Sources/NotchAI/
    App/        AppDelegate, launch lifecycle, menu bar, windows and wiring
    Island/     IslandState, IslandGeometry, IslandViewModel, IslandWindowController, IslandRootView
    Chat/       ChatModels, ChatStore, ChatManager, ChatView, MarkdownView
    AI/         AIProvider protocol + shared types, DeepSeekProvider, GeminiProvider, SSE parsing, catalogs
    Browser/    BrowserManager, BrowserTab, BrowserView, URL/search resolution
    Capture/    ScreenshotService (ScreenCaptureKit), exclusion logic, permission flow
    Settings/   AppSettings, SettingsStore, KeychainStore, ShortcutManager, SettingsView
    Support/    AppPaths, logging, small utilities
  Tests/NotchAITests/  XCTest suites for pure logic and stores
  scripts/build-app.sh  Release build + Info.plist + ad-hoc/dev-identity codesign + launch smoke test
  docs/, tasks/         capability map, docs, plan/todo
```

## Code style
Swift API design guidelines, one type per file when practical, `@MainActor` UI/persistence managers,
`async`/`await` + `AsyncThrowingStream` for providers, no force-unwraps outside startup paths,
`Logger`/`os_log` for diagnostics, explicit error enums with user-facing `LocalizedError` text.
Example:

```swift
@MainActor
final class ChatManager: ObservableObject {
    @Published private(set) var isStreaming = false
    private var streamTask: Task<Void, Never>?

    func send(text: String, attachments: [ImageAttachmentRef], model: AIModel) {
        guard !isStreaming, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        streamTask = Task { await streamReply(text: text, attachments: attachments, model: model) }
    }
}
```

## Testing strategy
XCTest via `swift test`. Unit coverage for deterministic logic (SSE parsing, request payload shape,
model capability mapping, URL/search resolution, settings/keychain round-trip with fakes, chat
persistence, island geometry for notch/non-notch, screenshot exclusion selection). Live UI and
permission-dependent flows are exercised after launch and reported honestly; a capability that needs
the user's TCC grant or API key is reported as "requires manual verification" until then.

## Boundaries
- Always: keep API keys in Keychain; never send screenshots without an explicit user send action;
  compile and run tests before claiming done; keep the app responsive off the main thread for network
  and capture work; leave unrelated projects untouched.
- Ask first: installing dependencies, changing the deployment target, or any operation that needs a
  new TCC permission the user has not been asked to grant.
- Never: hardcode or log credentials; disable SIP/security; use private APIs; upload screenshots or
  files anywhere; silently substitute a model the user did not choose.

## Provider contracts (verified 2026-11-06)
- DeepSeek: `POST https://api.deepseek.com/chat/completions`, `Authorization: Bearer`, OpenAI chat
  format, `stream: true` SSE terminated by `data: [DONE]`; models `deepseek-flash` (V4.1-Flash-1017,
  accepts images as `image_url` data URLs in user messages) and `deepseek-v4-pro`. `GET /models`
  lists models. Docs: https://api-docs.deepseek.com/guides/vision
- Gemini: current official **Interactions API**: `POST https://generativelanguage.googleapis.com/v1beta/interactions`
  with `x-goog-api-key`, `Api-Revision: 2026-05-20`; `input` content blocks (`text`, `image` with
  base64 `data` + `mime_type`), `system_instruction`, `stream: true` with `?alt=sse`; SSE events
  `event_type == "step.delta"` and `delta.type == "text"` carry text. Models are discovered with
  `GET /v1beta/models`. Current Flash models include `gemini-3.8-flash`, `gemini-3.7-flash`,
  `gemini-3.5-flash`, `gemini-flash-latest`; all Gemini model versions are multimodal (image input).
  Docs: https://aistudio.google.com/docs/text-generation, /docs/image-understanding,
  /api-reference/models/list-models.

## Success criteria
1. `swift build -c release` succeeds; `swift test` passes.
2. `build/NotchAI.app` launches as a background agent (no Dock icon by default, menu-bar item present),
   island appears centered at the top of the display and wraps the notch on notch hardware.
3. Island transitions collapsed↔expanded↔full with a stationary black shell and interior reveal, responds to hover, joins all
   Spaces and appears over full-screen apps; works on a notchless second display.
4. "Capture Screen" captures the selected display at native resolution, excludes every NotchAI window
   (island + optionally detached windows), previews the screenshot, allows remove/replace, attaches to
   chat, and never uploads without sending.
5. DeepSeek and Gemini stream responses with the user's Keychain-stored keys; unsupported image/model
   combinations produce a clear message and are never silently substituted; stop/regenerate/copy,
   multiple conversations, persistence, markdown/code rendering work.
6. Browser loads pages in WKWebView with address bar, back/forward/reload/stop, tabs, history,
   open-in-default-browser, detachable window, data clearing.
7. Settings has General/AI Providers/Screenshots/Browser/Privacy sections; launch-at-login and Dock
   policy work; API keys persist in Keychain; relaunch preserves settings, conversations, screenshots.
8. Known API/permission limits are documented; user is asked for TCC/API-key steps that cannot be
   automated.

## Open questions (defaults chosen, user may override)
- None blocking. Default screenshot shortcut ⌃⌥⌘4 (customizable); default search engine Google;
  default providers DeepSeek `deepseek-flash` and Gemini `gemini-3.8-flash`.
