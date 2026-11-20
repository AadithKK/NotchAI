# Verification log

## 2026-11-08 — Notch seam correction and finishing pass

Replaced the raised neck with inverse shoulders at the physical housing corners. Open anchors fill
the rounded corner wedges; collapsed anchors retain rounding. The decorative shoulder window is
click-through, cannot take keyboard focus, hides on collapse/sleep, and is included in both screenshot
exclusion paths. Positioning follows the actual notch midpoint. Content is ordered above decoration.

The shell remains opaque and stationary during opening and resizing. Expanded height is now 148
points. Reply lists and quotes render structurally, message actions have larger targets and copy
feedback, and the browser's empty page is opaque black when embedded in the island. Detached browser
windows retain a native background. DESIGN.md now describes the current geometry and behavior.

Evidence: eight focused markdown/join/lifecycle checks passed in the earlier phase of this pass.
The complete join was rendered from actual SwiftUI views and sampled across both sides of the seam.
Native app inspection confirmed compact navigation, full chat formatting and browser layout. The
final release bundle was installed and signature-verified. No live screenshot upload or provider
request was made during this pass. No measured performance multiplier is claimed. Multi-display
hardware and protected full-screen environments were not exercised.

Earlier dated entries below are historical and may describe superseded geometry.


## 2026-11-08 — UI and interaction polish

Preserved the opaque black notch shell, connecting neck, one-second opening dwell, and
Capture & Answer shortcut/badge behavior. Expanded panel is now 360 × 160 to give controls
more room without widening the notch tray.

- Reorganized full chat into a clean controls row and a conversation-title/model row. Added
  conversation history and New Conversation controls; grouped Settings, detach and confirmed
  reset under More. Active Pin has a visible accent treatment. Model names have bounded width.
- Larger 28-point utility targets, clearer secondary text, 14-point reply/composer type, focused
  composer outline, Command–Return to send, and a compact footer without duplicate model/actions.
- Expanded tray shows the customizable Capture & Answer shortcut instead of a private reply snippet
  when the feature is enabled. Missing-key status now checks the selected provider specifically.
- User scrolling pauses reply-following; Latest returns to the bottom. Scroll tracking compares only
  a Boolean geometry threshold, and respects reduced motion. Conversation selection resets following.
- Stable, equatable markdown content blocks avoid reformatting unchanged paragraphs when new text
  arrives. Last-assistant lookup is once per message-list evaluation rather than once per row.
- Browser loading indicator has a fixed-height slot so navigation does not shift the page viewport.

Validation: 38 focused render/markdown/browser/chat/settings checks passed. Final release bundle
built, installed and strictly signature-verified. Offscreen renders confirm shell geometry; native
controls appear as placeholders in ImageRenderer and are not visual proof. Live UI inspection was
blocked because the Mac was locked; no attempt was made to bypass the lock. App left in normal
background launch mode, not pinned preview mode. No quantified speedup claim.


## 2026-11-07 — Capture & Answer shortcut

Added a second configurable global shortcut, default Control–Option–Command–5. Settings →
Screenshots → Capture & Answer provides enable/disable and Record controls. Optional Codable
fields preserve existing saved settings; the original capture shortcut remains independent.
Carbon handlers now route by distinct hotkey IDs and pass unmatched events to the next handler.
Both hotkeys suspend while a shortcut is being recorded, preventing accidental capture/upload.

An explicit press captures the configured display (excluding island/content/status windows),
starts a fresh conversation, and sends only that capture with “Answer this” to the selected
image-capable model. Missing credentials, unsupported models, busy chat, or unsent composer
content produce an explanation. Model/chat changes during capture cancel the send; unowned
session captures are removed. Existing conversations, drafts and saved screenshot copies are kept.

The click-through status window beside the notch displays a green dot and Capturing…/Thinking….
On successful nonempty completion it displays Answered for 1.0 second, fades for 0.5 seconds,
and hides. The full reply opens pinned so it stays readable; Escape/collapse dismisses it.
Errors and cancellation do not claim success. Badge window is now 92 × 20 to fit its text.

Verification: 19 focused shortcut/settings/chat regression tests passed (including settings
migration and customization persistence). Release build, app bundle installation and strict
signature verification completed. No live screenshot was captured/uploaded to test this feature;
end-to-end behavior still depends on Screen Recording approval and the selected provider.


## 2026-11-07 — interaction performance pass

User reported lag across opening, typing, AI replies and browser scrolling. Before editing,
`sample <NotchAI PID> 3 10 -file work/performance/idle-before.txt` showed the main thread waiting
in AppKit's event loop; a process snapshot was 0.1% CPU / approximately 141 MiB RSS. This is an
idle measurement, not an interaction benchmark.

Changes:
- Replaced animated window-dimension changes with a single final layout and a short opacity
  transition, avoiding repeated SwiftUI/WKWebView reflow during expansion.
- Skip unchanged geometry publications; removed unused chat/browser subscriptions on the island root.
- Stable markdown block identities and equatable message/markdown views retain unchanged rows while
  composing and streaming instead of recreating every block with a new UUID.
- Coalesce incoming reply deltas over 33 ms. Completion, stop and termination flush pending text;
  reset cancels/discards it. Stream identity checks remain in place.
- Decode 384-pixel attachment thumbnails off the main thread once per attachment/view lifecycle,
  using canonical capture-directory checks and a bounded source file size. Request upload limits
  are unchanged.
- Skip redundant browser state publications when URL/loading/navigation values did not change.
- Preserve the solid-black notch shell, 1-second opening dwell, ordinary background-agent and
  full-screen auxiliary behavior. No lockdown bypass, process hiding, or privilege changes.

Verification: release build and `./scripts/build-app.sh` passed; installed signature passed
`codesign --verify --strict`; app relaunched. Focused chat persistence/reset/stop/regeneration and
browser regression suites: 42 tests, zero failures. No claim of a measured frame-rate improvement;
interaction smoothness under the user's actual pages/workload still needs observation.


## 2026-11-07 — solid-black notch color correction

User screenshot showed the adaptive gray material and black gradient looking disconnected.
The island now uses an opaque true-black surface throughout the neck, expanded panel and full
chat/browser shell. Its local dark color scheme keeps text readable regardless of macOS theme;
Settings and detached windows retain their normal appearance. Removed the neck gradient and
browser chrome material. Hover behavior and geometry are unchanged. Release build/install and
strict signature verification are the checks for this visual-only correction; no test suite rerun.


## 2026-11-07 — notch integration and background polish

User-directed redesign supersedes the earlier fixed-black detached-tray presentation and
key-window-based full-state hold. Opening dwell remains 1.0 seconds.

- Expanded panel is 360 × 152 with compact horizontal actions, semantic text colors, a native
  segmented chat/browser selector, system accent color and adaptive macOS material.
- A 14-point shaped neck joins the content to the physical black notch anchor. All content stays
  below the menu bar; no additional menu-bar hit area or bridge window was introduced.
- Full mode no longer stays open solely because it became key. Hover-away closes it after the
  existing 0.15-second policy delay (plus polling), except while pinned, a menu/modal/child window
  is active, or keyboard input occurred within the previous 1.5 seconds. Expanded delay remains 0.08.
- Pin explicitly keeps full mode open; Escape collapses. Manual collapse over the anchor requires
  pointer exit before opening can rearm. Six-point edge tolerance reduces accidental closing.
- First-click handling is enabled on the content hosting view; hover still never activates the app.
- Cached screen geometry replaces repeated NSScreen queries; timer callbacks no longer spawn Tasks.
  The timer pauses during sleep/inactive login sessions. Sleep hides all three island windows.
- Reveal respects animation/Reduce Motion settings; resize no longer jumps to its destination before
  starting the frame animation. Reduced transparency uses an opaque system background.
- Theme was set to System in the installed app. Dock visibility remains off; login preference was
  already enabled and was preserved. No process-hiding or detection-evasion mechanisms were added.
- Earlier reset fixes are retained: confirmed reset queues behind attachment preparation and prevents
  the pending send, reset does not emit a completion event, stale stream callbacks use reply identity.
- Attachment previews now check the allowed capture directory before reading a stored file reference.

Validation scope: release compilation and signed bundle installation; a visual review of the compact
panel and the native Settings appearance control. No additional test suite or provider/capture testing
was run after the user redirected this task from testing to improvements. The earlier 166-test result
belongs to the reset-only revision, not this redesign. Full-screen/external-display behavior and
real-world interaction edge cases have not been reverified for this revision.

Commands: `swift build -c release`; `./scripts/build-app.sh`; final installed signature verification.
Canonical installed copy: `~/Applications/NotchAI.app`.


Every claim below corresponds to a command that was actually executed on this Mac (macOS 27.0 arm64,
Xcode 27.2, Swift 6.4.2, MacBook Air Mac16,12 built-in 1470×956 pt @2x display, notch 179×32 pt).

## Automated (executed)
- `swift build` / `swift build -c release` — PASS.
- `swift test` — PASS: **164 tests, 0 failures** across AIProviderTests (41), CaptureTests (34),
  BrowserTests (18), plus Core/Island tests: geometry, hover region, animation-render, markdown,
  shortcuts, settings, chat store/manager (attachment lifetime, poisoning recovery, shared encoded
  budget, empty-response, conversation pinning), screenshot exclusion including additional windows.
- `./scripts/build-app.sh` — PASS: release build, staged bundle assembly, Apple Development signature,
  install to `~/Applications/NotchAI.app`; `codesign --verify --strict` passes on the installed app.
  (`build/NotchAI.app` is an artifact that can fail strict verification because the Documents workspace
  adds a `com.apple.FinderInfo` xattr; the canonical app is the installed copy.)
- `./scripts/smoke-test.sh` — PASS: the installed app launches and stays alive. CGWindowList probe:
  collapsed anchor is **179×32 at X=645 Y=0** on the 1470×956 display — the 179×32 true-black pill
  exactly matching the camera housing, plus a transparent a separate click-through badge window.
- Expanded/full live probe (via `NOTCHAI_START_STATE`): expanded content window is **420×200 at
  X=525 Y=32**; full content is **560×540 at X=455 Y=32**. Their top edge is the menu-bar bottom, so
  the menu bar is never covered while the island is open.
- Hover dwell and close timing (real cursor warp):
  - pointer rests on the notch: **still closed at 0.5 s**, **open at 1.4 s** (dwell policy 1.0 s).
  - pointer leaves: content panel ordered out **by 0.35 s** (close policy 0.08 s + 0.1 s poll).
- The open uses a SwiftUI spring reveal (scale 0.93→1, offset -12→0, opacity 0→1, 0.34 s spring);
  this is a visual animation and needs the user's eyes to judge.
- Hover (real cursor warp, no GUI automation permission needed):
  - warp to the hardware notch cutout `(735,10)` → content window appears within 0.6 s; anchor stays.
  - warp away to `(200,300)` → content window is ordered out within 1.2 s; anchor remains.
  - This works because hover is resolved from `NSEvent.mouseLocation` against
    `IslandGeometry.hoverRegion`; the notch cutout itself receives no mouse events.
- Offscreen renders (`Tests/NotchAITests/IslandRenderTests.swift`, ImageRenderer) produce
  `docs/renders/island-anchor.png` (179×32), `island-expanded.png` (420×200) and `island-full.png`
  (560×540) from the real SwiftUI views. Text fields render as placeholders in ImageRenderer; the
  renders are shape/layout checks, not screenshots.
- Persistence/reset iteration (`swift test` 164 tests): JSON store reload in a new manager restores
  conversations and the selected conversation id; reset clears messages, pending session captures and
  persisted history; a reset during a hanging stream leaves no stale reply; streaming checkpoints every
  1.5 s and `applicationWillTerminate` flushes state; the full-chat top bar renders a trash reset button
  (confirmed in the ImageRenderer full-state view). Chat history decode is per-entry: one unknown
  provider id keeps the remaining chats, and corrupt/unreadable files are copied to
  `conversations.unreadable-*.json` before the next save (a save is refused if the backup cannot be made).
  `regenerate()` keeps an earlier assistant answer when the trailing turn is a user message (for example
  after stopping before the first token).
- App icon generated from an authored 1024 px master (`scripts/make-icon.swift`), packed as
  `assets/AppIcon.icns`, installed in the bundle Resources, registered as `CFBundleIconFile=AppIcon`.

## Adversarial squad
Final squad run: **PASS**. It reproduced the two-window geometry, notch-cutout hover, auto-collapse,
dual-window screenshot-exclusion plumbing and the 164-test suite. The only finding was a low-severity
stale-doc issue; this file was rewritten in response.

## Requires the user's manual action (cannot be automated)
- Screen Recording TCC grant (System Settings prompt), then a live capture to prove the island windows
  are absent from the PNG and the screenshot attaches to chat.
- Entering a DeepSeek API key and/or a Google AI Studio key in Settings → AI Providers, then Test
  connection and a live streaming + screenshot round-trip.
- Approving launch-at-login (System Settings → General → Login Items) if macOS asks.
- Visual check of full chat/browser states, the Settings window, a full-screen app, and a second display.
- Full-state keyboard behavior (typing keeps it open; clicking elsewhere deactivates and the hover timer
  collapses it) cannot be exercised by the pinned preview harness.

## Known unverified risks
- ScreenCaptureKit exclusion is unit-tested (policy + dual-window plumbing) and the island windows are
  excluded by window id; pixel proof still needs the Screen Recording grant.
- Only one display is attached on this machine, so external-display placement is unit-tested only.
- Launch-at-login via SMAppService is only meaningful for the signed bundle.
