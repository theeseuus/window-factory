import Foundation

// Pure layout state. No AX, app activation, preferences or desktop ownership.
enum TileAxis: String, Codable, CaseIterable { case columns, rows }
indirect enum TileNode: Equatable {
  case leaf(UInt32)
  case split(UUID, TileAxis, Double, TileNode, TileNode)
  var ids: [UInt32] {
    switch self {
    case .leaf(let id): [id]
    case .split(_, _, _, let a, let b): a.ids + b.ids
    }
  }
  func inserting(_ id: UInt32, beside anchor: UInt32, axis: TileAxis) -> Self {
    switch self {
    case .leaf(let old): return old == anchor ? .split(UUID(), axis, 0.5, self, .leaf(id)) : self
    case .split(let key, let direction, let ratio, let a, let b):
      return .split(
        key, direction, ratio, a.inserting(id, beside: anchor, axis: axis),
        b.inserting(id, beside: anchor, axis: axis))
    }
  }
  func removing(_ id: UInt32) -> Self? {
    switch self {
    case .leaf(let old): return old == id ? nil : self
    case .split(let key, let axis, let ratio, let a, let b):
      let left = a.removing(id)
      let right = b.removing(id)
      if let left, let right { return .split(key, axis, ratio, left, right) }
      return left ?? right
    }
  }
  func pruning(to visible: Set<UInt32>) -> Self? {
    ids.filter { !visible.contains($0) }.reduce(Optional(self)) { node, id in node?.removing(id) }
  }
  func editing(_ key: UUID, ratio: Double? = nil, axis: TileAxis? = nil) -> Self {
    guard case .split(let id, let oldAxis, let oldRatio, let a, let b) = self else { return self }
    return .split(
      id, id == key ? axis ?? oldAxis : oldAxis,
      id == key ? min(0.85, max(0.15, ratio ?? oldRatio)) : oldRatio,
      a.editing(key, ratio: ratio, axis: axis), b.editing(key, ratio: ratio, axis: axis))
  }
  func balanced() -> Self {
    switch self {
    case .leaf: return self
    case .split(let id, let axis, _, let a, let b):
      return .split(id, axis, 0.5, a.balanced(), b.balanced())
    }
  }
  func parent(of window: UInt32) -> (UUID, TileAxis, Double, Bool)? {
    guard case .split(let id, let axis, let ratio, let a, let b) = self else { return nil }
    if a == .leaf(window) || b == .leaf(window) { return (id, axis, ratio, a.ids.contains(window)) }
    return a.parent(of: window) ?? b.parent(of: window)
  }
  func swapping(_ a: UInt32, _ b: UInt32) -> Self {
    switch self {
    case .leaf(let id): return .leaf(id == a ? b : id == b ? a : id)
    case .split(let id, let axis, let ratio, let left, let right):
      return .split(id, axis, ratio, left.swapping(a, b), right.swapping(a, b))
    }
  }
  static func balanced(_ ids: [UInt32], axis: TileAxis = .columns) -> Self? {
    guard !ids.isEmpty else { return nil }
    if ids.count == 1 { return .leaf(ids[0]) }
    let midpoint = (ids.count + 1) / 2
    return .split(
      UUID(), axis, 0.5,
      balanced(Array(ids[..<midpoint]), axis: axis == .columns ? .rows : .columns)!,
      balanced(Array(ids[midpoint...]), axis: axis == .columns ? .rows : .columns)!)
  }
}
struct TileDivider: Equatable {
  let id: UUID, axis: TileAxis, ratio: Double, region: Frame
}
struct TilePlan {
  var frames: [UInt32: Frame] = [:]
  var dividers: [TileDivider] = []
}
enum TileLayout {
  static func plan(_ tree: TileNode?, in screen: Frame, gap: Double, margin: Double) throws
    -> TilePlan
  {
    guard screen.w.isFinite, screen.h.isFinite, screen.w > 0, screen.h > 0, gap.isFinite,
      margin.isFinite, gap >= 0, margin >= 0
    else { throw FactoryError("Invalid tiling dimensions.") }
    var plan = TilePlan()
    func visit(_ node: TileNode, _ area: Frame) throws {
      guard area.w >= 120, area.h >= 80 else {
        throw FactoryError("Tiles would be too small. Float a window or reduce the gaps.")
      }
      switch node {
      case .leaf(let id):
        guard plan.frames[id] == nil else { throw FactoryError("Duplicate tiled window.") }
        plan.frames[id] = area
      case .split(let id, let axis, let ratio, let a, let b):
        guard ratio.isFinite, (0.15...0.85).contains(ratio) else {
          throw FactoryError("Invalid split ratio.")
        }
        plan.dividers.append(TileDivider(id: id, axis: axis, ratio: ratio, region: area))
        if axis == .columns {
          let width = (area.w - gap) * ratio
          try visit(a, Frame(x: area.x, y: area.y, w: width, h: area.h))
          try visit(
            b, Frame(x: area.x + width + gap, y: area.y, w: area.w - width - gap, h: area.h))
        } else {
          let height = (area.h - gap) * ratio
          try visit(a, Frame(x: area.x, y: area.y, w: area.w, h: height))
          try visit(
            b, Frame(x: area.x, y: area.y + height + gap, w: area.w, h: area.h - height - gap))
        }
      }
    }
    if let tree {
      try visit(
        tree,
        Frame(
          x: screen.x + margin, y: screen.y + margin, w: screen.w - 2 * margin,
          h: screen.h - 2 * margin))
    }
    return plan
  }
}
