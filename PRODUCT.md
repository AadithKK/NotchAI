# Product: NotchAI

Mode: Operate (a native utility the visitor uses to complete tasks), with a premium Pinned aesthetic
from the brief.

## What it is
A native macOS agent app that lives in the MacBook camera notch as a Dynamic Island. Collapsed, it is
a pill around the notch; expanded, it offers Chat / Browser / Capture Screen; full, it is a compact
AI conversation or mini browser. It runs as a background menu-bar agent (optional Dock icon), launches
at login, works across Spaces and full-screen apps, and works on notchless/external displays.

## Who it is for
The machine's owner: a MacBook Air user who wants fast AI help, a quick browser, and full-screen
screenshots that exclude the island overlay, without leaving the current app.

## Jobs to be done
1. Ask an AI question from anywhere and see the answer stream in.
2. Screenshot the whole display (island excluded) and send it with a question.
3. Browse a page quietly inside the island, or detach it into a window.
4. Configure provider keys, capture behavior and shortcuts in a native Settings window.

## Design direction (pinned by the brief)
NotchBox-inspired, native macOS, Apple Dynamic Island interaction language. Dark glass island on both
appearances, system typography, restrained blue accent, subtle hover response, spring transitions,
no neon, no glow everywhere, no decorative card grids. Settings and detached windows follow the system
light/dark appearance.

## Product truth / constraints
- Two providers only: user-supplied DeepSeek and Gemini keys, stored in Keychain.
- Never upload screenshots on their own; they stay local until the user presses Send, uses Capture & Answer, or deliberately starts Watch Region (which says so and shows a persistent badge).
- No private APIs, no security bypasses; permission denials handled with clear recovery copy.
