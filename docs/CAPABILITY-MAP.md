# Capability Map: NotchAI

Reviewed scope: the request bundles five independently testable capabilities. Module ids are
stable and each maps to a spec/plan section and source folder.

| Module id | Responsibility | Depends on | Source |
|---|---|---|---|
| `island` | NSPanel Dynamic Island: collapsed/expanded/full, notch + external-display geometry, Spaces/full-screen behavior, hover/spring animations, menu-bar agent lifecycle | — | `Sources/NotchAI/Island`, `Sources/NotchAI/App` |
| `capture` | ScreenCaptureKit full-display capture at native resolution, island/app-window exclusion, permission flow, global shortcut, attachment handoff | `island` (window id) | `Sources/NotchAI/Capture`, `Sources/NotchAI/Settings` |
| `ai-chat` | Conversation store, streaming DeepSeek + Gemini providers, image attachments, model capability handling, regenerate/stop/copy, markdown | — | `Sources/NotchAI/AI`, `Sources/NotchAI/Chat` |
| `browser` | WKWebView tabs, address/search resolution, navigation, history, detachable window, privacy/data clearing | — | `Sources/NotchAI/Browser` |
| `settings` | Native Settings window, launch at login, dock policy, appearance, Keychain credentials, screenshot/browser preferences, privacy deletion | `ai-chat`, `capture`, `island` | `Sources/NotchAI/Settings` |

Build order (dependency direction, no cycles):
`island` → `capture` → `ai-chat` → `browser` → `settings` (settings last because it edits every other module's state; `island` first because `capture` needs its window identity).

Verification per module: `island` = geometry unit tests + live launch/hover/space checks; `capture` = exclusion logic tests + live permission/capture check; `ai-chat` = SSE/payload/capability tests + live connection test with user keys; `browser` = URL resolver/nav-state tests + live page load; `settings` = persistence/keychain round-trip tests + live Settings window.
