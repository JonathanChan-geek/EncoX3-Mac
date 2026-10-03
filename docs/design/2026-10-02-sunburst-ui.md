# Sunburst UI implementation

The approved concepts are retained locally in the ignored `output/imagegen/sunburst-ui-20261002/` directory. Generated images and preview galleries are not runtime dependencies. The running interface is implemented in native SwiftUI/AppKit, not a screenshot overlay. The artwork is resolution-independent SwiftUI drawing; desktop blur is real `NSVisualEffectView` material. Exact lighting varies with desktop content and the system appearance.

## Geometry and interactions

- 380pt panel width, 548pt base height including the anchor; 22pt outer radius, 14pt grouped settings radius, 22pt content inset.
- Four 72pt noise tiles, system-blue selected mode, a 32pt segmented intensity control with a raised neutral selected segment.
- Monochrome settings rows expand inline; opening a row does not send any command. Only activating a choice invokes the existing manager write path; checkmarks remain driven by device replies/readback.
- Expanded height follows option count. Screen-height limits introduce vertical scrolling only when needed. The top edge stays anchored during resizing.
- Unknown/stale battery data appears as an em dash and a hollow battery. Disconnected mode/intensity highlights are cleared. Actual errors remain visible; reconnect countdowns no longer reserve an orange debug strip.
- Dual-device information remains in More → 双设备连接. Existing shortcuts, scenes, notifications, About and settings access remain available.
- The native nonactivating panel dismisses on Escape, outside click or a switch to another application. Status-item clicks retain toggle behavior; native menu tracking is excluded from premature dismissal. Opening does not depend on activating the accessory app first.

## Reproduce visual QA without a device

```sh
swift run EncoMenu --render-previews=output/ui-implementation
swift run EncoMenu --preview=light
swift run EncoMenu --preview=dark
swift run EncoMenu --preview=disconnected
swift run EncoMenu --preview=connecting
swift run EncoMenu --preview=equalizer
swift run EncoMenu --preview=spatial
```

These explicit preview paths never create `MenuManager`, initialize Bluetooth or write to headphones. The interactive preview uses the production native panel and `PanelView`, with local fixture actions. Its menu-bar label is `Enco UI`, distinguishing it from the real app. The static renderer uses `NSHostingView` to capture native controls at the display's backing scale; an ImageRenderer-only snapshot cannot capture the native scroll view correctly.

## Validation

- All seven native snapshots (including an error state) visually checked for clipping, unknown data, disabled/selected states, Chinese text and expanded lists.
- Existing offline protocol checks: 312 passed, 0 failed.
- Release packaging and strict ad-hoc signature verification through `build.sh`.
- The packaged offline preview was operated through native accessibility: EQ expanded with six choices, selecting 纯享人声 updated the value and checkmark; opening spatial audio collapsed EQ; selecting 跟随 updated its value/checkmark. More opened and Escape dismissed its menu. These were local preview actions, not device writes.
- Device protocol, transport and command definitions were not changed. No headphone setting writes are part of this UI acceptance.

### Startup follow-up, 2026-10-03

- Fixed the first-click opening path by using a nonactivating `NSPanel`, disabling automatic hiding on deactivation, and removing application activation from the production show/toggle path.
- Release build and installed bundle signature passed; installed and packaged executables matched by SHA-256.
- Installed app cold launch opened RFCOMM in 2.08 seconds and completed its first parsed-state refresh in 3.02 seconds. No setting writes were used for this check.
- The user confirmed that first-click opening works after installation. Local diagnostics also recorded left-click events followed by a visible key panel.
- Raw diagnostic logs remain in ignored `evidence/local/startup-20261003/`.

The source build uses Command Line Tools without the SwiftUI State macro plugin. Hover feedback therefore uses an AppKit tracking view; expanded UI state lives in the manager's immutable snapshot flow.
