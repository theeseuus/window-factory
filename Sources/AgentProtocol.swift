import Foundation

enum AgentCommand: String, Codable, CaseIterable {
  case status, capabilities, layouts, windows, capture, restore, establish, job, cancel
  case apps
  case appOpen = "app-open"
  case newWindow = "new-window"
  case tilingStatus = "tiling-status"
  case tiling, window
  case layoutRename = "layout-rename"
  case layoutDelete = "layout-delete"
  case layoutOrder = "layout-order"
  case layoutExport = "layout-export"
  case layoutImport = "layout-import"
  var layoutOperation: Bool { [.capture, .restore, .establish].contains(self) }
  var toolMutation: Bool {
    [
      .appOpen, .newWindow, .tiling, .window, .layoutRename, .layoutDelete, .layoutOrder,
      .layoutImport,
    ].contains(self)
  }
  var modifies: Bool { layoutOperation || toolMutation }
}
struct AgentRequest: Codable, Equatable {
  var version = 1
  var id = UUID()
  var command: AgentCommand
  var name: String?
  var display: UInt32?
  var space: UInt64?
  var jobID: UUID?
  var replace = false
  var instanceID: UUID?
  var bundleID: String?, action: String?, geometry: String?, axis: String?, newName: String?
  var windowID: UInt32?, direction: Int?, splitID: UUID?, ratio: Double?, gap: Double?,
    margin: Double?
  var names: [String]?, catalog: Catalog?, confirm: Bool?
  func validate() throws {
    guard version == 1 else { throw AgentFailure("unsupported_version", "Use protocol version 1.") }
    if command.modifies || command == .windows {
      guard let display, display > 0, let space, space > 0 else {
        throw AgentFailure("context_required", "Supply --display and --space from status.")
      }
    } else if display != nil || space != nil {
      throw AgentFailure("invalid_request", "This command does not take a desktop context.")
    }
    let named = command.layoutOperation || [.layoutRename, .layoutDelete].contains(command)
    if named {
      guard let name, try Recipe.normalizedName(name) == name else {
        throw AgentFailure("invalid_name", "Supply a valid layout name.")
      }
    } else if name != nil {
      throw AgentFailure("invalid_request", "This command does not take a layout name.")
    }
    if command == .job || command == .cancel {
      guard jobID != nil else { throw AgentFailure("job_required", "Supply --job.") }
    } else if jobID != nil {
      throw AgentFailure("invalid_request", "This command does not take a job ID.")
    }
    if replace && command != .capture {
      throw AgentFailure("invalid_request", "--replace applies only to Capture.")
    }
    var supplied = Set<String>()
    if bundleID != nil { supplied.insert("bundleID") }
    if action != nil { supplied.insert("action") }
    if geometry != nil { supplied.insert("geometry") }
    if axis != nil { supplied.insert("axis") }
    if newName != nil { supplied.insert("newName") }
    if windowID != nil { supplied.insert("windowID") }
    if direction != nil { supplied.insert("direction") }
    if splitID != nil { supplied.insert("splitID") }
    if ratio != nil { supplied.insert("ratio") }
    if gap != nil { supplied.insert("gap") }
    if margin != nil { supplied.insert("margin") }
    if names != nil { supplied.insert("names") }
    if catalog != nil { supplied.insert("catalog") }
    if confirm != nil { supplied.insert("confirm") }
    let allowed: Set<String>
    switch command {
    case .appOpen, .newWindow:
      allowed = ["bundleID"]
      guard let bundleID, !bundleID.isEmpty, bundleID.utf8.count <= 255,
        bundleID.unicodeScalars.allSatisfy({
          CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
          ).contains($0)
        })
      else { throw AgentFailure("invalid_app", "Supply an exact application bundle ID.") }
    case .tiling:
      allowed = ["action", "windowID", "splitID", "ratio", "axis", "gap", "margin"]
      guard let action,
        [
          "enable", "disable", "pause", "resume", "select", "float", "rejoin", "split", "balance",
          "swap", "restore-positions", "options",
        ].contains(action)
      else { throw AgentFailure("invalid_action", "Unknown tiling action.") }
      if action == "options", gap == nil && margin == nil && axis == nil {throw AgentFailure("invalid_options", "Supply gap, margin or axis.")}
      let windowActions = ["select", "float", "rejoin", "swap"].contains(action)
      guard windowActions == (windowID != nil), windowID.map({ $0 > 0 }) ?? true else {
        throw AgentFailure(
          "invalid_window", "This tiling action requires exactly its window target.")
      }
      if action == "split" {
        guard splitID != nil, ratio != nil || axis != nil else {
          throw AgentFailure("invalid_split", "Supply a split ID and ratio or axis.")
        }
      } else if splitID != nil || ratio != nil {
        throw AgentFailure("invalid_split", "Split fields apply only to split editing.")
      }
      if action != "split" && action != "options" && axis != nil {
        throw AgentFailure("invalid_request", "Axis is not valid for this action.")
      }
      if action != "options" && (gap != nil || margin != nil) {
        throw AgentFailure("invalid_request", "Gaps apply only to options.")
      }
      if let axis, !TileAxis.allCases.map(\.rawValue).contains(axis) {
        throw AgentFailure("invalid_axis", "Use columns or rows.")
      }
      if let ratio, !ratio.isFinite || !(0.15...0.85).contains(ratio) {
        throw AgentFailure("invalid_ratio", "Use a split ratio from 0.15 to 0.85.")
      }
      for value in [gap, margin].compactMap({ $0 }) {
        guard value.isFinite, (0...48).contains(value) else {
          throw AgentFailure("invalid_gap", "Use gaps/margins from 0 to 48.")
        }
      }
    case .window:
      allowed = ["action", "windowID", "geometry", "direction"]
      guard let windowID, windowID > 0, let action,
        ["geometry", "focus", "stash", "restore-stash", "move-space", "accordion"].contains(action)
      else { throw AgentFailure("invalid_window", "Supply a window ID and supported action.") }
      if action == "geometry" {
        guard let geometry, GeometryCommand(rawValue: geometry) != nil else {
          throw AgentFailure("invalid_geometry", "Supply a supported geometry command.")
        }
      } else if geometry != nil {
        throw AgentFailure("invalid_geometry", "Geometry applies only to its action.")
      }
      if action == "move-space" {
        guard direction == -1 || direction == 1 else {
          throw AgentFailure("invalid_direction", "Use direction -1 or 1.")
        }
      } else if direction != nil {
        throw AgentFailure("invalid_direction", "Direction applies only to move-space.")
      }
    case .layoutRename:
      allowed = ["newName"]
      guard let newName, try Recipe.normalizedName(newName) == newName else {
        throw AgentFailure("invalid_name", "Supply --new-name.")
      }
    case .layoutDelete:
      allowed = ["confirm"]
      guard confirm == true else {
        throw AgentFailure(
          "confirmation_required", "Use --confirm to delete the named saved layout.")
      }
    case .layoutOrder:
      allowed = ["names"]
      guard let names, !names.isEmpty, names.count <= 4096, Set(names).count == names.count else {
        throw AgentFailure("invalid_order", "Supply unique layout names.")
      }
    case .layoutImport:
      allowed = ["catalog"]
      guard let catalog else {
        throw AgentFailure("invalid_catalog", "Supply a catalog using --input.")
      }
      try catalog.validate()
    default: allowed = []
    }
    guard supplied.isSubset(of: allowed) else {
      throw AgentFailure("invalid_request", "This command has unexpected fields.")
    }
  }
  static func decode(_ data: Data) throws -> Self {
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: data) } catch {
      throw AgentFailure("invalid_request", "Malformed JSON request.")
    }
    let allowed: Set<String> = [
      "version", "id", "command", "name", "display", "space", "jobID", "replace", "instanceID",
      "bundleID", "action", "geometry", "axis", "newName", "windowID", "direction", "splitID",
      "ratio", "gap", "margin", "names", "catalog", "confirm",
    ]
    guard let fields = object as? [String: Any], Set(fields.keys).isSubset(of: allowed) else {
      throw AgentFailure("invalid_request", "Unknown request fields.")
    }
    let request: Self
    do { request = try JSONDecoder().decode(Self.self, from: data) } catch {
      throw AgentFailure("invalid_request", "Malformed protocol request.")
    }
    try request.validate()
    return request
  }
}
struct AgentFailure: Error, LocalizedError, Codable {
  let code: String, message: String
  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
  var errorDescription: String? { message }
}
struct AgentDesktop: Codable {
  let display: UInt32, space: UInt64, frame: Frame
}
struct AgentWindow: Codable {
  let id: UInt32, pid: Int32, bundleID: String, appName: String, frame: Frame
}
struct AgentStatus: Codable {
  let instanceID: UUID, agentAccess: Bool, accessibility: Bool, busy: Bool
  let desktops: [AgentDesktop]
  var stashedWindowIDs: [UInt32]?
}
struct AgentJob: Codable {
  let id: UUID, requestID: UUID, command: AgentCommand, name: String, context: AgentDesktop,
    startedAt: Date
  var status = "running", progress = "Starting"
  var finishedAt: Date?
  var receipt: Receipt?
  var recipe: Recipe?
  var error: AgentFailure?
  var tools: AgentToolResult?
  var sideEffectsPossible = false
  var terminal: Bool { status != "running" }
}
struct AgentPayload: Codable {
  var tools: AgentToolResult?
  var status: AgentStatus?
  var commands: [String]?
  var layouts: [Recipe]?
  var windows: [AgentWindow]?
  var job: AgentJob?
}
struct AgentResponse: Codable {
  var version = 1
  var requestID: UUID?
  var instanceID: UUID?
  var ok: Bool
  var code: String
  var result: AgentPayload?
  var error: AgentFailure?
  static func failure(_ error: Error, id: UUID? = nil, instance: UUID? = nil) -> Self {
    let failure =
      error as? AgentFailure ?? AgentFailure("operation_failed", error.localizedDescription)
    return Self(requestID: id, instanceID: instance, ok: false, code: failure.code, error: failure)
  }
  func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(self))
      ?? Data("{\"version\":1,\"ok\":false,\"code\":\"encoding_failed\"}".utf8)
  }
  static func decode(_ data: Data) throws -> Self {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Self.self, from: data)
  }
}

struct AgentApp: Codable {
  let bundleID: String, name: String, path: String
  let running: Bool
}
struct AgentTile: Codable {
  let windowID: UInt32
  let plannedFrame: Frame
  let observedFrame: Frame?
}
struct AgentSplit: Codable {
  let id: UUID, axis: String
  let ratio: Double
  let region: Frame
}
struct AgentTiling: Codable {
  let enabled: Bool, paused: Bool, busy: Bool
  let display: UInt32?, space: UInt64?
  let selected: UInt32?, tiled: [AgentTile], floating: [UInt32], parked: [UInt32],
    splits: [AgentSplit]
  let gap: Double, margin: Double, axis: String, message: String
  let excluded: [String], undoAvailable: Bool
}
struct AgentToolResult: Codable {
  var apps: [AgentApp]?, tiling: AgentTiling?, catalog: Catalog?, names: [String]?
  var display: UInt32?, space: UInt64?
  var windowID: UInt32?, pid: Int32?, frame: Frame?, message: String?
}
