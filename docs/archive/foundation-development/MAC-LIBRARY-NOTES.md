# Native macOS Library shell — issue 137

## Scope and integration

Base and parent: 23b654f96a4a9c1b42c350f5b592815de4912950.
Worker branch: codex/foundation-macos.

`FoundationMacLibraryShell` is a macOS-only presentation wrapper. The coordinator
adds its source file to the app target and calls it from the macOS root:

```swift
FoundationMacLibraryShell(
    selection: $selectedTab,
    showsMiniPlayer: !player.queue.isEmpty
) { destination in
    destinationContent(destination)
} miniPlayer: {
    miniPlayer()
}
```

Supply destination bodies without a NavigationStack. This wrapper owns exactly
one detail NavigationStack. Changing the top-level section changes its identity,
removing obsolete pushed destinations; the root retains catalog models. The
existing destination tasks must still enforce cancellation and late publication
ownership. The wrapper itself owns no tasks, models, player or provider.

Home, New, Library and Search reuse the shared destination labels and selection.
Inactive section content stays honest in the root. Native sidebar selection,
keyboard focus, resizing, sidebar toggle and back navigation are left to SwiftUI.
The detail mini-player remains visible across top-level selection while a queue
exists; the root supplies its existing controls and sheet presentation.

The original `VelacantoRootView.macOSRoot` guided the sidebar/detail arrangement
and detail playback accessory. No original controllers, transport, search binding,
queue overlay or view modifiers were copied. No custom navigation coordinator,
shortcuts, event monitors or provider-name branches were introduced.

Apple's native composition is documented in
[NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)
and [TN3154](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view).

## Verification and remaining acceptance

Owned-source strict swift-format lint and git diff --check passed. No Xcode,
application launch, private-server request or device action ran in this worker.
No new model test was added for this presentation-only wrapper: a constructor
assertion would not prove native navigation behavior. Coordinator macOS compilation
and exact-candidate visual/interaction checks remain required.

Integration acceptance checklist:

- Resize at the minimum window size and a larger size; sidebar and Library
  content remain usable. Toggle sidebar through the native toolbar.
- Select Home, New, Library and Search by mouse and keyboard. Sidebar selection
  follows content; inactive destinations show their unavailable state.
- Open a Library category and a detail, navigate Back, switch away, and return.
  There is one navigation bar/stack. Obsolete tasks do not publish; retained root
  models avoid repeated page reads. Measure through the existing catalog tests.
- With Keyboard Navigation enabled, Tab reaches sidebar, content, visible menus,
  and mini-player controls. Space/Return activate the focused control normally;
  this wrapper deliberately defines no global Space shortcut that steals input.
- VoiceOver announces destination labels and selected state. Test the supplied
  mini-player buttons and item action menus independently at the integration root.
- Secondary click and each visible ellipsis menu expose equivalent supported
  item actions, including pin/unpin. Menu titles reflect current state. Those
  menus belong to the shared Library implementation, not this shell.
- Play a loaded item, navigate among sections, and open/close the supplied player
  sheet. Playback remains unchanged and the accessory does not cover the final row.

Cold/warm shell-owned request budget is zero. Selecting a destination may invoke
its existing visible content task; the shell neither adds nor suppresses requests.
It adds no persistent state, identifiers, diagnostics, credentials or API access.
The frozen player, transport, credentials and all iOS paths remain untouched.
