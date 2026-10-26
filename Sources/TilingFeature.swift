import AppKit

// Composition boundary for tiling. Existing owners only expose small handoff hooks.
@MainActor
final class TilingFeature {
  let controller: TilingController, panel: TilingPanel, settings: TilingSettings
  init(
    library: LibraryWindow, geometry: DirectWindowControls?, stash: DirectStashControls?,
    accordion: DirectAccordionControls?, spaceMove: DirectSpaceMoveControls?,
    switcher: DirectSwitcherControls?
  ) {
    let options = TilingOptions()
    let events = TilingEvents()
    controller = TilingController(
      backend: .live(services: library.coordinator.services), options: options, events: events)
    panel = TilingPanel(controller: controller)
    settings = TilingSettings(options: options)
    settings.connect(controller)
    controller.changed = { [weak panel, weak settings] in
      panel?.refresh()
      settings?.refreshSession()
    }
    controller.externalBusy = {
      [weak library, weak geometry, weak stash, weak accordion, weak spaceMove, weak switcher,weak controller] in
      (library?.task != nil && controller?.agentOperation != true) || library?.frozen != nil || geometry?.isBusy == true
        || stash?.isBusy == true || accordion?.isBusy == true || spaceMove?.isMoving == true
        || switcher?.isOpen == true || ShortcutRecorder.current?.isRecording == true
    }
    controller.parkedWindows = { [weak stash] in stash?.windowIDs ?? [] }
    geometry?.willChangeFrame = { [weak controller] in controller?.floatForGeometry($0) }
    stash?.tilingTransition = { [weak controller] in controller?.stashTransition($0, restoring: $1)
    }
    accordion?.willArrange = { [weak controller] in controller?.pause("Accordion paused tiling") }
    spaceMove?.willMove = { [weak controller] in controller?.yieldForControl() }
    library.coordinator.willApply = { [weak controller] context in
      guard controller?.desktop?.display == context.display,
        controller?.desktop?.space == context.space
      else { return }
      controller?.pause("Layout operation paused tiling")
    }
    // Resume one deferred reconciliation after a direct owner completes. No polling.
    let geometryChanged = geometry?.changed
    let stashChanged = stash?.changed
    let moveChanged = spaceMove?.changed
    let switcherChanged = switcher?.changed
    geometry?.changed = { [weak controller] in
      geometryChanged?()
      controller?.schedule()
    }
    stash?.changed = { [weak controller] in
      stashChanged?()
      controller?.schedule()
    }
    spaceMove?.changed = { [weak controller] in
      moveChanged?()
      controller?.schedule()
    }
    switcher?.changed = { [weak controller] in
      switcherChanged?()
      controller?.schedule()
    }
  }
  func show() { panel.show() }
  func toggle() {
    let window = panel.window
    switch FactoryLaunchPolicy.libraryAction(
      visible: window.isVisible, key: window.isKeyWindow, active: NSApp.isActive,
      onActiveSpace: window.isOnActiveSpace,
      modal: NSApp.modalWindow != nil || window.attachedSheet != nil)
    {
    case .show: panel.show()
    case .close: window.close()
    case .ignore: break
    }
  }
  func stop() {
    controller.stop()
    panel.stop()
  }
}
