import AppKit


struct Receipt: Codable {
    var created = 0, placed = 0, reused = 0, missing = 0, extras = 0
    var failures: [String] = []
    var summary: String {
        "\(placed) placed · \(created) created · \(reused) reused · \(missing) missing · \(extras) extra"
        + (failures.isEmpty ? "" : "\n"+failures.joined(separator:"\n"))
    }
}

@MainActor
final class Coordinator {
    let services = MacServices()
    var willApply: ((Context)->Void)?
    let adapters: [String:Adapter]
    init(registry: AdapterRegistry) { adapters = Dictionary(uniqueKeysWithValues:registry.adapters.map { ($0.bundleID,$0) }) }
    func apply(_ recipe: Recipe,establish: Bool,context: Context,progress: (String)->Void) async throws -> Receipt {
        try recipe.validate(); try services.requireAccess(); try context.check()
        willApply?(context)
        var receipt = Receipt(), created = Set<UInt32>()
        let initial = try await services.collect(context)
        let initialIDs = Set(initial.map(\.id))
        // One application at a time; creation decisions use a fresh local count.
        for bundle in Set(recipe.windows.map(\.bundleID)).sorted() {
            let targets = recipe.windows.filter { $0.bundleID == bundle }
            let label = targets[0].appName
            progress("\(establish ? "Establishing" : "Restoring") \(label)…")
            var live = try await services.collect(context)
            var local = live.filter { $0.bundleID == bundle }
            if establish && local.count < targets.count {
                if let adapter = adapters[bundle] {
                    do {
                        try services.checkInstalled(adapter)
                        if try services.running(adapter) == nil {
                            let before = Set(live.map(\.id))
                            try await services.launch(adapter,context)
                            for _ in 0..<30 {
                                try await Task.sleep(for:.milliseconds(100)); try context.check()
                                live = try await services.collect(context)
                                if live.contains(where:{ $0.bundleID == bundle && !before.contains($0.id) }) { break }
                            }
                            for window in live where window.bundleID == bundle && !before.contains(window.id) { created.insert(window.id) }
                            local = live.filter { $0.bundleID == bundle }
                        }
                        // No retries of a dispatched New Window request. A late
                        // window is an honest timeout, never a second command.
                        let budget = max(0,targets.count-local.count)
                        for _ in 0..<budget {
                            live = try await services.collect(context)
                            local = live.filter { $0.bundleID == bundle }
                            if local.count >= targets.count { break }
                            let before = Set(local.map(\.id))
                            try await services.create(adapter,context)
                            var discovered: [LiveWindow] = []
                            for _ in 0..<40 {
                                try await Task.sleep(for:.milliseconds(100)); try context.check()
                                local = try await services.collect(context).filter { $0.bundleID == bundle }
                                discovered = local.filter { !before.contains($0.id) }
                                if !discovered.isEmpty { break }
                            }
                            guard !discovered.isEmpty else { throw FactoryError("\(label): no new eligible window appeared here.") }
                            for window in discovered { created.insert(window.id) }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { try context.check(); receipt.failures.append(error.localizedDescription) }
                } else { receipt.failures.append("\(label): independent-window creation is not supported.") }
            }
            live = try await services.collect(context)
            let candidates = live.filter { $0.bundleID == bundle }.map {
                Candidate(id:$0.id,bundleID:$0.bundleID,frame:$0.frame.normalized(in:context.frame))
            }
            var sub = recipe; sub.windows = targets
            let assignments = match(sub,candidates)
            receipt.missing += assignments.missing.count
            receipt.extras += assignments.extras.count
            for assignment in assignments.assignments {
                guard let window = live.first(where:{ $0.id == assignment.candidate.id }) else { continue }
                do {
                    try await services.place(window,assignment.slot.frame.absolute(in:context.frame),context,
                        new:created.contains(window.id),policy:adapters[bundle]?.placementPolicy)
                    receipt.placed += 1
                    if initialIDs.contains(window.id) { receipt.reused += 1 }
                } catch is CancellationError { throw CancellationError() }
                catch { try context.check(); receipt.failures.append(error.localizedDescription) }
            }
        }
        try context.check(); receipt.created = created.count
        let final = try await services.collect(context)
        let complete = match(recipe,final.map { Candidate(id:$0.id,bundleID:$0.bundleID,frame:$0.frame.normalized(in:context.frame)) })
        receipt.missing = complete.missing.count; receipt.extras = complete.extras.count
        return receipt
    }
}
