# Design: NotchAI

Native SwiftUI content in AppKit panels, with standard separate Settings and detached windows.

## Surface and geometry
The island is opaque RGB black, matching the physical camera housing in both system appearances.
No material, gray tint, border, shadow, gradient, or translucent fade at the notch connection.
Text uses semantic foreground colors in an explicitly dark island environment; detached windows
keep their normal macOS appearance.

The anchor follows the physical notch bounds reported by the display. Collapsed, it retains its
rounded lower corners. Open, those corners fill black and the content shell hangs from the menu-bar bottom with a flat top
(square top corners, rounded bottom) so no wedge of menu bar shows beside the housing; 12-point inverse shoulders cover the housing-to-shell step. A one-point overlap prevents a seam. The shoulders
are a separate click-through, non-key window; interactive content remains below the menu bar.
Notchless displays retain a rounded pill and have no decorative shoulder window.

Expanded: 360 × 148 points, 20-point outer radius, 14-point padding. Full: 560 × 540 points,
22-point outer radius. Controls use restrained 8–10-point corners and native SF Symbols.
The system accent marks capture, selection, and focus. No permanent colored status decorations.

## Motion and interaction
The window frame updates once per state transition, avoiding repeated WebKit and text layout. The
black shell then grows from the notch footprint (or from the previous panel size on expanded/full
switches) by animating only a clip shape with a short spring; the interior fades in 0.07 s later with
a three-point move. Closing stays instant. Reduce Motion and the animation preference disable that movement.
Hover requires one second continuously. Leaving expanded/full begins the 0.08/0.15-second close
policy, sampled by a 10 Hz monitor. Menus, active typing, or explicit Pin protect ongoing interaction.
Manual collapse requires leaving the hover region before it can open again. Escape collapses.
Sleep and session lock hide all island windows and suspend hover work.

## Content
Expanded: compact brand/model header, Settings and Collapse, Chat/Browser/Capture actions, and
Capture & Answer shortcut footer. Full: native segmented Chat/Browser selector, history/new chat,
Pin, More and Collapse; separate conversation title and bounded model picker.

Chat uses 14-point body/composer type, hanging-indent bullets and numbers, block quotes and code.
Message copy/regenerate controls have 26-point targets, accessible labels and copy confirmation.
The composer stays at the bottom; scrolling away pauses automatic reply-following.
Browser chrome and its empty page share the black island surface; loaded websites keep their
own appearance. Detached browser start pages use the standard window background.

Capture & Answer defaults to Control–Option–Command–5 and is customizable. A click-through green
dot reports progress beside the notch, then shows Answered for one second and fades for half a
second. Its response opens pinned. Normal capture remains Control–Option–Command–4.

## Rendering cost
Keep shell placement out of streaming updates. Reuse stable markdown blocks, batch streamed text,
load bounded image thumbnails asynchronously, and avoid duplicate browser state publications.
Do not claim a measured speedup without profiling. No continuous decorative animation.
