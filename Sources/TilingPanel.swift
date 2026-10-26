import AppKit
import UniformTypeIdentifiers

@MainActor
final class TilingCanvas: NSView {
  weak var controller: TilingController?
  var activate: ((UInt32) -> Void)?
  private var dragged: TileDivider?, dragPoint: NSPoint?
  override var isFlipped: Bool { true }
  private var canvas: NSRect {
    LibraryPresentation.canvas(
      in: bounds, inset: 12, aspect: controller?.desktop.map { $0.frame.w / $0.frame.h } ?? 1.6)
  }
  private func point(_ x: Double, _ y: Double) -> NSPoint {
    guard let frame = controller?.desktop?.frame else { return .zero }
    return NSPoint(
      x: canvas.minX + (x - frame.x) / frame.w * canvas.width,
      y: canvas.minY + (y - frame.y) / frame.h * canvas.height)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor.windowBackgroundColor.setFill()
    NSBezierPath(roundedRect: canvas, xRadius: 6, yRadius: 6).fill()
    guard let controller, let plan = try? controller.plan() else { return }
    for (id, frame) in plan.frames {
      let start = point(frame.x, frame.y)
      let end = point(frame.x + frame.w, frame.y + frame.h)
      let rect = NSRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
      let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
      NSColor.controlAccentColor.withAlphaComponent(id == controller.selected ? 0.4 : 0.12)
        .setFill()
      path.fill()
      NSColor.controlAccentColor.setStroke()
      path.lineWidth = id == controller.selected ? 2 : 1
      path.stroke()
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byTruncatingTail
      (controller.known[id]?.name ?? "Window").draw(
        in: rect.insetBy(dx: 8, dy: 8),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
          .paragraphStyle: style,
        ])
    }
    for divider in plan.dividers {
      let line = dividerLine(divider)
      NSColor.secondaryLabelColor.setStroke()
      let path = NSBezierPath()
      path.move(to: line.0)
      path.line(to: line.1)
      path.lineWidth = 3
      path.stroke()
    }
    if let dragged, let dragPoint {
      NSColor.controlAccentColor.setStroke()
      let path = NSBezierPath()
      if dragged.axis == .columns {
        path.move(to: NSPoint(x: dragPoint.x, y: canvas.minY))
        path.line(to: NSPoint(x: dragPoint.x, y: canvas.maxY))
      } else {
        path.move(to: NSPoint(x: canvas.minX, y: dragPoint.y))
        path.line(to: NSPoint(x: canvas.maxX, y: dragPoint.y))
      }
      path.lineWidth = 2
      path.stroke()
    }
  }
  private func dividerLine(_ d: TileDivider) -> (NSPoint, NSPoint) {
    let gap = controller?.options.gap ?? 0
    if d.axis == .columns {
      let x = d.region.x + (d.region.w - gap) * d.ratio + gap / 2
      return (point(x, d.region.y + 8), point(x, d.region.y + d.region.h - 8))
    }
    let y = d.region.y + (d.region.h - gap) * d.ratio + gap / 2
    return (point(d.region.x + 8, y), point(d.region.x + d.region.w - 8, y))
  }
  override func mouseDown(with event: NSEvent) {
    guard let controller, let plan = try? controller.plan(), !controller.isBusy else { return }
    let p = convert(event.locationInWindow, from: nil)
    dragged = plan.dividers.reversed().first { d in
      let line = dividerLine(d)
      return d.axis == .columns
        ? abs(p.x - line.0.x) < 7 && p.y >= line.0.y && p.y <= line.1.y
        : abs(p.y - line.0.y) < 7 && p.x >= line.0.x && p.x <= line.1.x
    }
    if dragged != nil {
      dragPoint = p
      return
    }
    for (id, f) in plan.frames {
      let a = point(f.x, f.y)
      let b = point(f.x + f.w, f.y + f.h)
      if NSRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).contains(p) {
        controller.select(id)
        activate?(id)
        break
      }
    }
  }
  override func mouseDragged(with event: NSEvent) {
    guard dragged != nil else { return }
    dragPoint = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      dragged = nil
      dragPoint = nil
      needsDisplay = true
    }
    guard let d = dragged, let controller, let frame = controller.desktop?.frame else { return }
    let p = convert(event.locationInWindow, from: nil)
    let x = frame.x + (p.x - canvas.minX) / canvas.width * frame.w
    let y = frame.y + (p.y - canvas.minY) / canvas.height * frame.h
    let gap = controller.options.gap
    let ratio =
      d.axis == .columns
      ? (x - d.region.x - gap / 2) / (d.region.w - gap)
      : (y - d.region.y - gap / 2) / (d.region.h - gap)
    controller.editSplit(d.id, ratio: ratio)
  }
}

@MainActor
final class TilingPanel: NSObject {
  let window: NSWindow, canvas = TilingCanvas()
  private let controller: TilingController
  private let enabled = NSSwitch(), status = NSTextField(wrappingLabelWithString: "Tiling off"),
    selection = NSPopUpButton()
  private let pause = NSButton(title: "Pause", target: nil, action: nil),
    floating = NSButton(title: "Float", target: nil, action: nil)
  private var ids: [UInt32] = [], monitor: Any?
  private var actions: [NSButton] = []
  init(controller: TilingController) {
    self.controller = controller
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 570, height: 475),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.title = "Window Factory Tiling"
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace]
    window.minSize = NSSize(width: 540, height: 440)
    enabled.target = self
    enabled.action = #selector(toggle)
    enabled.setAccessibilityLabel("Tiling session")
    let head = NSStackView(views: [
      NSTextField(labelWithString: "Tiling session"), enabled, NSView(), pause,
    ])
    head.spacing = 10
    pause.target = self
    pause.action = #selector(pauseAction)
    pause.keyEquivalent = "p"
    pause.keyEquivalentModifierMask = []
    canvas.controller = controller
    canvas.setAccessibilityLabel("Tiling tree; drag dividers to resize splits")
    selection.target = self
    selection.action = #selector(selectWindow)
    let smaller = button("−", #selector(shrink), "-")
    let larger = button("+", #selector(grow), "+")
    smaller.toolTip = "Reduce selected split — −"
    larger.toolTip = "Enlarge selected split — +"
    let selected = NSStackView(views: [selection, floating, smaller, larger])
    selected.spacing = 8
    floating.target = self
    floating.action = #selector(floatAction)
    floating.keyEquivalent = "f"
    floating.keyEquivalentModifierMask = []
    let splits = NSStackView(views: [
      button("Side by side", #selector(columns), "v"), button("Top / bottom", #selector(rows), "h"),
      button("Balance", #selector(balance), "b"), button("Swap", #selector(swap), "s"),
    ])
    splits.spacing = 8
    let restore = button("Restore previous positions", #selector(restorePositions), "")
    let stack = NSStackView(views: [head, canvas, selected, splits, restore, status])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    window.contentView!.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18),
      stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18),
      stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18),
      stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
      head.widthAnchor.constraint(equalTo: stack.widthAnchor),
      canvas.widthAnchor.constraint(equalTo: stack.widthAnchor),
      canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
      selected.widthAnchor.constraint(equalTo: stack.widthAnchor),
      selection.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
      status.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    status.textColor = .secondaryLabelColor
    status.font = .systemFont(ofSize: 12)
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let handled = MainActor.assumeIsolated { () -> Bool in
        guard let self, event.window === self.window else { return false }
        if event.keyCode == 53 {
          self.window.close()
          return true
        }
        if event.keyCode == 125 || event.keyCode == 126, !self.ids.isEmpty {
          let index = self.controller.selected.flatMap { self.ids.firstIndex(of: $0) } ?? 0
          self.controller.select(
            self.ids[max(0, min(self.ids.count - 1, index + (event.keyCode == 125 ? 1 : -1)))])
          return true
        }
        return false
      }
      return handled ? nil : event
    }
    refresh()
  }
  private func button(_ title: String, _ action: Selector, _ key: String) -> NSButton {
    let b = NSButton(title: title, target: self, action: action)
    b.bezelStyle = .rounded
    b.keyEquivalent = key
    b.keyEquivalentModifierMask = []
    actions.append(b)
    return b
  }
  func refresh() {
    for action in actions { action.isEnabled = controller.enabled && !controller.isBusy }
    selection.isEnabled = !controller.known.isEmpty && !controller.isBusy
    enabled.state = controller.enabled ? .on : .off
    enabled.isEnabled = !controller.isBusy
    status.stringValue = controller.message
    pause.title = controller.paused ? "Resume" : "Pause"
    pause.isEnabled = controller.enabled
    ids = controller.known.keys.sorted()
    selection.removeAllItems()
    var ordinals: [String: Int] = [:]
    for id in ids {
      let record = controller.known[id]!
      ordinals[record.bundleID, default: 0] += 1
      let multiple = controller.known.values.filter { $0.bundleID == record.bundleID }.count > 1
      let suffix =
        controller.suspended.contains(id)
        ? " (stashed)" : controller.floating.contains(id) ? " (floating)" : ""
      selection.addItem(
        withTitle: record.name + (multiple ? " · window \(ordinals[record.bundleID]!)" : "")
          + suffix)
    }
    if let id = controller.selected, let index = ids.firstIndex(of: id) {
      selection.selectItem(at: index)
    }
    floating.title =
      controller.selected.map { controller.floating.contains($0) ? "Rejoin" : "Float" } ?? "Float"
    floating.isEnabled = controller.selected != nil && !controller.isBusy
    canvas.needsDisplay = true
  }
  func show() {
    controller.event(0, moved: false)
    refresh()
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc private func toggle() {
    if controller.enabled { controller.disable() } else { controller.enable() }
  }
  @objc private func pauseAction() {
    if controller.paused { controller.resume() } else { controller.pause() }
  }
  @objc private func selectWindow() {
    if ids.indices.contains(selection.indexOfSelectedItem) {
      controller.select(ids[selection.indexOfSelectedItem])
    }
  }
  @objc private func floatAction() { controller.toggleFloat() }
  @objc private func columns() { controller.splitSelected(.columns) }
  @objc private func rows() { controller.splitSelected(.rows) }
  @objc private func balance() { controller.balance() }
  @objc private func swap() { controller.swapNext() }
  @objc private func shrink() { controller.resizeSelected(-0.05) }
  @objc private func grow() { controller.resizeSelected(0.05) }
  @objc private func restorePositions() { controller.restoreOriginals() }
  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    window.orderOut(nil)
  }
}

@MainActor
final class TilingSettings: NSObject {
  let view = NSView()
  let session = NSSwitch()
  private weak var controller: TilingController?
  private let sessionStatus = NSTextField(wrappingLabelWithString: "")
  private let options: TilingOptions, gap = NSStepper(), margin = NSStepper(),
    axis = NSPopUpButton(), excluded = NSPopUpButton()
  private let gapLabel = NSTextField(labelWithString: ""),
    marginLabel = NSTextField(labelWithString: "")
  init(options: TilingOptions) {
    self.options = options
    super.init()
    session.target = self
    session.action = #selector(changeSession)
    session.isEnabled = false
    sessionStatus.textColor = .secondaryLabelColor
    sessionStatus.isHidden = true
    gap.minValue = 0
    gap.maxValue = 48
    gap.increment = 2
    gap.doubleValue = options.gap
    gap.target = self
    gap.action = #selector(update)
    margin.minValue = 0
    margin.maxValue = 48
    margin.increment = 2
    margin.doubleValue = options.margin
    margin.target = self
    margin.action = #selector(update)
    axis.addItems(withTitles: ["Side by side", "Top / bottom"])
    axis.selectItem(at: options.axis == .columns ? 0 : 1)
    axis.target = self
    axis.action = #selector(update)
    let add = NSButton(title: "Add…", target: self, action: #selector(addApp))
    let remove = NSButton(title: "Remove", target: self, action: #selector(removeApp))
    let stack = NSStackView(views: [
      row("Tiling session", session), sessionStatus,
      row("Window gaps", NSStackView(views: [gapLabel, gap])),
      row("Outer margins", NSStackView(views: [marginLabel, margin])), row("New split", axis),
      NSTextField(labelWithString: "Excluded applications"),
      NSStackView(views: [excluded, add, remove]),
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
    ])
    refresh()
  }
  func connect(_ controller: TilingController) {
    self.controller = controller
    refreshSession()
  }
  func refreshSession() {
    session.state = controller?.enabled == true ? .on : .off
    session.isEnabled = controller != nil && controller?.isBusy != true
    let detail =
      controller.map { $0.paused || $0.message == "Tiling on another desktop" ? $0.message : "" }
      ?? ""
    sessionStatus.stringValue = detail
    sessionStatus.isHidden = detail.isEmpty
  }
  @objc private func changeSession() {
    guard let controller else { return }
    if controller.enabled { controller.disable() } else { controller.enable() }
    refreshSession()
  }
  private func row(_ title: String, _ control: NSView) -> NSView {
    control.setAccessibilityLabel(title)
    let label = NSTextField(labelWithString: title)
    label.widthAnchor.constraint(equalToConstant: 150).isActive = true
    let row = NSStackView(views: [label, control])
    row.spacing = 16
    return row
  }
  private func refresh() {
    gapLabel.stringValue = "\(Int(options.gap)) pt"
    marginLabel.stringValue = "\(Int(options.margin)) pt"
    excluded.removeAllItems()
    excluded.addItems(withTitles: options.excluded.sorted())
    if excluded.numberOfItems == 0 { excluded.addItem(withTitle: "None") }
  }
  @objc private func update() {
    options.gap = gap.doubleValue
    options.margin = margin.doubleValue
    options.axis = axis.indexOfSelectedItem == 0 ? .columns : .rows
    refresh()
  }
  @objc private func addApp() {
    let picker = NSOpenPanel()
    picker.allowedContentTypes = [.applicationBundle]
    picker.canChooseDirectories = false
    if picker.runModal() == .OK, let url = picker.url, let id = Bundle(url: url)?.bundleIdentifier {
      options.excluded.insert(id)
      refresh()
    }
  }
  @objc private func removeApp() {
    if let id = excluded.titleOfSelectedItem {
      options.excluded.remove(id)
      refresh()
    }
  }
}
