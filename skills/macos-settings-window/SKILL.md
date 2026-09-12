---
name: macos-settings-window
description: Use when building or fixing a macOS settings window, a full-height or floating sidebar, traffic lights sitting on a sidebar, an inset sidebar panel whose radius disagrees with the window, a sidebar toggle that will not go away, or hosted SwiftUI content pushed down by a titlebar safe area.
---

# Native macOS Settings Window

## Decision rules

1. Let AppKit own the window. Make an `NSSplitViewController` the window's own `contentViewController`; `allowsFullHeightLayout` is window-level and does not reach a split view nested inside a SwiftUI hosting view.
2. Build the sidebar with `NSSplitViewItem(sidebarWithViewController:)`. Set `allowsFullHeightLayout = true` and `canCollapse = false`. The sidebar toggle exists only for a collapsible column; making the item non-collapsible removes it without toolbar surgery.
3. Use one `NSVisualEffectView` for the window surface. Set `blendingMode = .behindWindow`, pin it to the split controller's full bounds, and keep it as the bottom-most subview. Let the system sidebar material layer over it. Per-pane effect views create two unrelated surfaces, a loud divider, and one pane that reads as a hole.
4. Clear the titlebar safe area at the hosting boundary with `NSHostingController.safeAreaRegions = []`. `.ignoresSafeArea` inside the SwiftUI root cannot clear the safe area imposed by the hosting controller. Add each column's own inset after clearing it.
5. Treat hosted roots as rendered snapshots. When selection or context changes, assign fresh root views to both hosting controllers; otherwise the sidebar highlights the new row while the detail pane shows the old section until the window reopens.
6. Keep settings as one reused window. Replace the `Settings` scene with `CommandGroup(replacing: .appSettings)` that calls the shared window controller.

```swift
.commands {
    CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
            SettingsWindowController.shared.show(
                appearance: appearance,
                model: model,
                registry: registry
            )
        }
    }
}
```

## AppKit recipe

- Create the sidebar item with `NSSplitViewItem(sidebarWithViewController: sidebarHosting)`.
- Set `sidebarItem.allowsFullHeightLayout = true`, `sidebarItem.canCollapse = false`, and `sidebarItem.titlebarSeparatorStyle = .none`. Start with `minimumThickness = 150`, `maximumThickness = 280`, and divider position around 172 pt; allow user dragging.
- Add a normal detail item, set `splitView.isVertical = true`, and set `splitView.dividerStyle = .thin`.
- Create the single `NSVisualEffectView` with the split view's bounds, `material = .underWindowBackground`, `blendingMode = .behindWindow`, and active-state following. Add it below every split subview and constrain or autoresize it to the full split bounds.
- Create the window with `.titled`, `.closable`, `.miniaturizable`, `.resizable`, and `.fullSizeContentView`. Set `isOpaque = false`, `backgroundColor = .clear`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, and `toolbarStyle = .unified`.
- Install an item-less `NSToolbar` anyway. It may contain only the system flexible-space and split-view-separator items. Removing the toolbar removes the traffic lights.
- Assign `contentViewController` before sizing. AppKit adopts the controller's fitting size and discards the initializer's `contentRect`; call `setContentSize` afterwards, then `center()`. Start around 720 × 460 pt with a minimum around 660 × 460 pt. Set `isRestorable = false` so a stale frame cannot resurrect.
- Set `window.setAccessibilitySubrole(.floatingWindow)` so tiling window managers do not tile the settings surface.

## SwiftUI bridge

- Wrap the AppKit controller in `NSViewControllerRepresentable`, and pass the selection binding into the sidebar hosting root.
- Set `sidebarHosting.safeAreaRegions = []` and `detailHosting.safeAreaRegions = []` immediately after creating the hosting controllers.
- After clearing the hosting safe area, inset the sidebar by roughly 46 pt to clear the traffic lights. Inset the detail heading by roughly 20 pt. Do not rely on `.ignoresSafeArea` in either SwiftUI root.
- On every representable update and every selection change, assign a new sidebar root and detail root. Keep the current model, registry, and selection in the window controller so the shared window can refresh both columns without rebuilding the window.

## Failure modes

- **SwiftUI `Settings` + `NavigationSplitView`:** the sidebar is an inset rounded panel, its radius disagrees with the window, and the traffic lights sit above it; `allowsFullHeightLayout` has no window-level effect.
- **`.toolbar(removing: .sidebarToggle)`:** the sidebar column is evicted from the titlebar region and the traffic lights are stranded rather than the toggle disappearing.
- **`.toolbar(.hidden, for: .windowToolbar)`:** the entire toolbar goes away and the traffic lights disappear with it.
- **Toolbar item surgery:** inspecting or removing items does not find a hideable `NSButton`; the toolbar holds only `NSToolbarFlexibleSpaceItem` and `com.apple.SwiftUI.splitViewSeparator-0`.
- **Searching for an `NSButton`:** there is no stable button to hide. Make the split item non-collapsible instead.
- **Per-pane effect views:** the panes blur differently, the divider becomes loud, and one pane reads as a hole. Keep exactly one window effect view behind the split.
- **Nested AppKit split:** the sidebar remains inset and `allowsFullHeightLayout` appears ineffective because the window owns a SwiftUI hosting controller instead of the split controller.
- **Missing safe-area reset:** both hosted columns start below the titlebar; the sidebar leaves excessive space under the traffic lights and the detail heading is pushed down. Clear `safeAreaRegions` at the hosting controller.
- **Stale hosted roots:** the sidebar selection changes while the detail pane remains on the previous section until reopening. Push both fresh roots on every selection update.
- **No toolbar:** the settings window opens without traffic lights. Keep an item-less `NSToolbar` installed.
- **Sizing before adoption:** the requested initializer rectangle is ignored or the window opens at an unexpected size. Assign `contentViewController`, then set content size and center.

## Verification

1. Enumerate windows and match the settings window by size before capturing. Raise the settings window first; it sits inside the main window's rectangle.
2. Capture corner evidence with `screencapture -x -R<x>,<y>,140,140`. `sips -c H W --cropOffset 0 0` crops from the image centre, not the origin; use `sips -Z` only to resize. Do not use a centre crop to judge traffic lights or a corner radius.
3. Verify the traffic lights sit on the sidebar's material and that the sidebar reaches the window's full height. Verify the sidebar shares the window corner instead of drawing its own rounded rectangle.
4. Judge the material by wallpaper detail: desktop detail must be equally blurred in both panes. A pane that reads as a hole or a divider that becomes loud indicates multiple effect views or the wrong stacking order.
5. Change selection while the window remains open. The sidebar highlight and detail heading/content must change together. Reopen only after this live-update check; reopening can hide stale hosted roots.
6. Verify the sidebar toggle is absent while the traffic lights remain, the window is not tiled, and the settings window reuses its existing instance on repeated open commands.
