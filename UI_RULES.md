# UI rules

1. **SwiftUI first for new or redesigned app UI.** Keep AppKit for rendering,
   window management, or interactions needing its APIs. Record the reason for a
   new AppKit exception. Adopt SwiftUI incrementally; preserve working behavior.
2. **System components first in either framework.** Use native toolbars, search
   fields, lists, menus, dialogs and controls. Let macOS own standard metrics,
   focus, hover, disabled and inactive appearances. Avoid custom replicas.
3. **One owner for window chrome.** Preserve native traffic lights, transparent
   titlebars, full-height media and working drag regions. Measure native geometry
   when custom overlays must align with it; do not reposition system buttons.
4. **One playback state and action contract.** Inline, standalone and fullscreen
   presentations share commands, labels, availability and accessibility behavior.
   Keep the existing single video surface; deliberate layout differences are OK.
5. **Use materials by role.** Prefer system-provided backgrounds. Apply custom
   Liquid Glass sparingly to controls/navigation, never decorative content cards.
   Clear glass belongs over media; regular glass suits text-heavy controls.
6. **Dark only; accessibility always.** Respect contrast, transparency, motion,
   text scaling and keyboard/VoiceOver settings. Prefer semantic styles and
   intrinsic sizing; deliberate custom appearance values belong in DesignTokens.
7. **Preserve accepted product decisions.** Keep approved pane expansion,
   toggle placement and playback geometry. Resolve differences between main and
   older worktrees before redesigning; preserve user customizations and settings.
8. **Verify the affected behavior.** Read code and geometry values first; run
   focused checks and show the changed native window on MacMini-005. Capture
   screenshots only when requested or needed to resolve visual uncertainty.
   Tests alone do not establish visual acceptance. A small edit does not trigger
   a full UI sweep.

SwiftUI-first is UniPlayer policy, not an Apple requirement to remove AppKit.
See Apple's [incremental adoption guidance](https://developer.apple.com/swiftui/),
[Liquid Glass guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass),
and [macOS 27 AppKit updates](https://developer.apple.com/videos/play/wwdc2026/289/).
