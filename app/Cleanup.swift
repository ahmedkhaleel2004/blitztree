import AppKit
import SwiftUI
import Observation

/// A folder that is safe to delete because a tool rebuilds or re-downloads
/// it on demand: package installs, build output, caches.
nonisolated struct CleanupItem: Identifiable, Sendable {
    let node: Int
    let path: String
    let display: String
    let kind: String
    let bytes: UInt64
    var id: Int { node }
}

nonisolated enum Cleanup {
    /// The Rust engine selects candidates for both the panel and JSON CLI.
    /// Swift only supplies presentation paths; rules and labels live in cleanup.rs.
    static func find(in tree: Tree) -> [CleanupItem] {
        let home = NSHomeDirectory()
        return (0..<tree.cleanupCount).map { index in
            let node = Int(tree.cleanupNodes[index])
            let path = tree.path(node)
            var display = tree.displayPath(node)
            if display.hasPrefix(home) { display = "~" + display.dropFirst(home.count) }
            return CleanupItem(node: node, path: path, display: display,
                               kind: tree.cleanupDescription(index), bytes: tree.alloc[node])
        }
    }
}

/// A manual cleanup batch keeps file coordination off the main actor and
/// prevents repeated clicks from moving the same captured selection twice.
@Observable
@MainActor
final class CleanupTrashBatch {
    private(set) var running = false
    /// Keep errors when the inspector closes during a background batch.
    private(set) var failures: [String] = []

    func clearFailures() { failures = [] }

    @discardableResult
    func start(_ items: [CleanupItem], completion: @escaping ([String]) -> Void) -> Task<Void, Never>? {
        guard !running else { return nil }
        running = true
        return Task {
            let failed = await Task.detached(priority: .userInitiated) {
                var failed: [String] = []
                for item in items {
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    } catch {
                        failed.append("\(item.display): \(error.localizedDescription)")
                    }
                }
                return failed
            }.value
            failures.append(contentsOf: failed)
            running = false
            completion(failed)
        }
    }
}

/// Right-hand inspector: what can be reclaimed, pick, trash, rescan. While an
/// agent cleanup is on screen, the whole panel is that run.
struct CleanupPanel: View {
    let model: ScanModel
    @State private var picked: Set<Int> = []
    @State private var confirming = false

    private var agent: InstalledAgent? { model.preferredAgent }

    private var pickedItems: [CleanupItem] { model.cleanup.filter { picked.contains($0.id) } }
    private var pickedBytes: UInt64 { pickedItems.reduce(0) { $0 + $1.bytes } }
    private var totalBytes: UInt64 { model.cleanup.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        Group {
            if let run = model.agentRun {
                AgentRunView(run: run, model: model, retry: { model.restart(run) }) {
                    run.cancel()
                    withAnimation(.snappy) { model.agentRun = nil }
                }
                .transition(.opacity)
            } else {
                reclaimable
                    .transition(.opacity)
            }
        }
        .confirmationDialog(picked.count == 1 ? "Move 1 folder to the Trash?" : "Move \(String(picked.count)) folders to the Trash?", isPresented: $confirming) {
            Button("Move to Trash (\(Fmt.size(pickedBytes)))", role: .destructive) { trashPicked() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can put them back from the Trash until you empty it. The tools that made them rebuild them when needed.")
        }
        .alert("Some folders couldn't be moved", isPresented: .constant(!model.cleanupTrash.failures.isEmpty)) {
            Button("OK") { model.cleanupTrash.clearFailures() }
        } message: {
            Text(model.cleanupTrash.failures.joined(separator: "\n"))
        }
    }

    private var reclaimable: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaimable")
                    .font(.headline)
                Text(model.cleanup.isEmpty ? "Nothing large to clean up"
                     : "\(Fmt.size(totalBytes)) in \(String(model.cleanup.count)) folders")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            List(model.cleanup) { item in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { picked.contains(item.id) },
                        set: { on in if on { picked.insert(item.id) } else { picked.remove(item.id) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.display)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(item.kind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(Fmt.size(item.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .help(item.display)
                .onTapGesture { model.selection = item.node }
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    }
                }
            }
            .listStyle(.inset)
            .disabled(model.cleanupTrash.running)

            Divider()
            VStack(spacing: 8) {
                agentButton
                    .disabled(model.cleanupTrash.running)
                Button {
                    confirming = true
                } label: {
                    Text(picked.isEmpty ? "Select folders to clean up"
                         : "Move \(String(picked.count)) to Trash · \(Fmt.size(pickedBytes))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(picked.isEmpty || model.scanning || model.cleanupTrash.running)
            }
            .padding(12)
        }
    }

    /// One click starts Claude Code or Codex in the background; the menu picks which.
    @ViewBuilder private var agentButton: some View {
        if let agent {
            HStack(spacing: 6) {
                Button {
                    model.startAgent(agent)
                } label: {
                    Label("Clean up with \(agent.kind.name)", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("\(agent.kind.name) reads this scan and suggests what can go. Nothing is removed until you say so.")
                if model.agentEnv.ready.count > 1 || !model.providerStore.providers.isEmpty {
                    Menu {
                        ForEach(model.agentEnv.ready) { other in
                            Button("Clean up with \(other.kind.name)") { model.startAgent(other) }
                        }
                        if !model.providerStore.providers.isEmpty {
                            Divider()
                            ForEach(model.providerStore.providers) { provider in
                                Button("Clean up with \(provider.displayName)") { model.startProvider(provider) }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .fixedSize()
                    .help("Choose the agent")
                }
            }
            .disabled(model.tree == nil || model.scanning)
        } else if let provider = model.preferredProvider {
            // A custom endpoint needs no install or sign-in: it is ready once
            // its model and key are set in Settings.
            Button {
                model.startProvider(provider)
            } label: {
                Label("Clean up with \(provider.displayName)", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.tree == nil || model.scanning)
            .help("\(provider.displayName) reads this scan and suggests what can go. Nothing is removed until you say so.")
        } else if let setup = model.agentSetup {
            SetupProgress(setup: setup) {
                setup.cancel()
                model.agentSetup = nil
            } retry: {
                model.setUp(setup.kind)
            }
        } else if model.agentEnv.loaded {
            setupOffer
        }
    }

    /// Nothing ready: one click installs an agent and signs it in. Offer the
    /// one already installed first; else Codex, which a free ChatGPT account runs.
    private var setupOffer: some View {
        let installed = model.agentEnv.agents.first
        let kind = installed?.kind ?? .codex
        let other: AgentKind = kind == .codex ? .claude : .codex
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Let AI clean up for you", systemImage: "sparkles")
                    .font(.headline)
                Text(installed == nil
                     ? "\(kind.name) reads this scan and plans what can go. \(kind == .codex ? String(localized: "Free with a ChatGPT account.") : String(localized: "Needs a Claude Pro plan."))"
                     : "Sign in to \(kind.name) and it plans what can go from this scan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Button {
                model.setUp(kind)
            } label: {
                Text(installed == nil ? "Set up \(kind.name)" : "Sign in to \(kind.name)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Use \(other.name) instead") { model.setUp(other) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Divider()
            // The panel is not only about the two CLIs: any OpenAI- or
            // Anthropic-compatible endpoint works, set up in Settings.
            VStack(alignment: .leading, spacing: 4) {
                Text("Or use any model — a self-hosted server, a relay, a gateway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsLink {
                    Label("Set up a model provider", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trashPicked() {
        model.cleanupTrash.start(pickedItems) { _ in
            picked = []
            // The batch clears its busy state before this final rescan.
            model.startScan()
        }
    }

}

// MARK: - Agent run

/// The agent's work, live: its steps while it looks, the plan as it is
/// written, then BlitzTree's own cleanup and the space it gave back.
private struct AgentRunView: View {
    let run: AgentRun
    let model: ScanModel
    let retry: () -> Void
    let close: () -> Void

    private var safe: [PlanItem] { run.items.filter { $0.spec.group != "ask" } }
    private var ask: [PlanItem] { run.items.filter { $0.spec.group == "ask" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if [.staged, .deleting, .done].contains(run.phase), hero > 0 {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Fmt.size(hero))
                                .font(.system(size: 40, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(heroLine)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 6)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .animation(.snappy, value: hero)
                    }
                    if run.phase == .thinking || !run.items.isEmpty {
                        steps
                    }
                    if !safe.isEmpty { section(String(localized: "Safe to remove"), safe) }
                    if !ask.isEmpty { section(String(localized: "Your call"), ask) }
                    if run.phase == .thinking {
                        SkeletonCard()
                        if run.items.isEmpty { SkeletonCard().opacity(0.6) }
                    }
                    if case .failed(let message) = run.phase {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .animation(.snappy, value: run.items.count)
            }
            .scrollIndicators(.never)
            Divider()
            footer
                .padding(14)
        }
        // QA and demos only: BZ_AUTOFREE=<seconds> approves the plan after a pause.
        .onChange(of: run.phase) {
            guard run.phase == .planned || run.phase == .staged,
                  let delay = ProcessInfo.processInfo.environment["BZ_AUTOFREE"].flatMap(Double.init) else { return }
            Task {
                try? await Task.sleep(for: .seconds(delay))
                if run.phase == .planned { run.moveToTrash() } else { run.deleteForGood(env: model.agentEnv) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: busy)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 4)
            if run.phase == .thinking { Clock(run: run) }
        }
        .animation(.snappy, value: run.phase)
    }

    private var busy: Bool { [.thinking, .trashing, .deleting].contains(run.phase) }

    /// The big number: what waits to be deleted, then what was freed.
    private var hero: UInt64 { run.phase == .done ? (run.reclaimed ?? run.freed) : run.pendingBytes }

    private var title: String {
        switch run.phase {
        case .thinking: String(localized: "\(run.displayName) is looking")
        case .planned: run.items.isEmpty ? String(localized: "Nothing worth removing") : String(localized: "Here's the plan")
        case .trashing: String(localized: "Moving to the Trash")
        case .staged: String(localized: "In the Trash")
        case .deleting: String(localized: "Deleting")
        case .done: String(localized: "All clean")
        case .failed: String(localized: "\(run.displayName) couldn't finish")
        }
    }

    private var subtitle: String {
        switch run.phase {
        case .thinking: run.items.isEmpty ? String(localized: "Reading your scan, nothing is touched") : String(localized: "Writing the plan")
        case .planned: run.summary
        case .trashing: String(localized: "Nothing is deleted yet")
        case .staged: stagedLine
        case .deleting: String(localized: "Only what this cleanup moved; the rest of your Trash stays")
        case .done: finishedLine
        case .failed: String(localized: "Nothing was changed.")
        }
    }

    private var heroLine: String {
        guard run.phase == .done else { return String(localized: "ready to delete") }
        // Less can come back than the cards said: clones share blocks, and a
        // tool's own cleanup may leave part of its folder.
        if let back = run.reclaimed, run.freed > back + back / 10 {
            return String(localized: "back on your disk · the cards estimated \(Fmt.size(run.freed))")
        }
        return String(localized: "back on your disk")
    }

    private var stagedLine: String {
        let waiting = run.targets.contains { $0.isCommand && $0.status == .waiting }
        return waiting ? String(localized: "Put anything back from the Trash, or delete it for good. Tool caches are cleared then too.")
            : String(localized: "Put anything back from the Trash, or delete it for good.")
    }

    private var finishedLine: String {
        let failed = run.items.filter { if case .failed = $0.status { true } else { false } }.count
        if failed > 0 { return failed == 1 ? String(localized: "One item couldn't be cleaned.") : String(localized: "\(String(failed)) items couldn't be cleaned.") }
        return run.freed > 0 ? String(localized: "Rescanned. The map is up to date.") : String(localized: "Nothing needed doing.")
    }

    // MARK: Steps

    /// The last few things the agent did; the newest is live.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            let shown = Array(run.steps.suffix(run.phase == .thinking ? 4 : 1).enumerated())
            ForEach(shown, id: \.element) { index, step in
                let live = run.phase == .thinking && index == shown.count - 1
                HStack(spacing: 7) {
                    Group {
                        if live {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 14)
                    Text(run.phase == .thinking ? step : String(localized: "Planned in \(String(Int((run.planSeconds ?? 0).rounded()))) s"))
                        .font(.callout)
                        .foregroundStyle(live ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .modifier(Shimmer(active: live))
                }
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .padding(.bottom, 4)
    }

    private func section(_ name: String, _ items: [PlanItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
            ForEach(items) { item in
                PlanCard(item: item, editable: run.phase == .planned, current: run.current == item.id) {
                    guard let tree = model.tree, let path = item.paths.first,
                          let node = tree.node(at: path) else { return }
                    model.selection = node
                }
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch run.phase {
        case .thinking:
            Button("Stop", action: close)
                .frame(maxWidth: .infinity)
        case .planned:
            VStack(spacing: 8) {
                Button {
                    run.moveToTrash()
                } label: {
                    Text(run.selectedBytes == 0 ? "Pick what to remove"
                         : run.trashBytes > 0 ? "Move \(Fmt.size(run.trashBytes)) to Trash" : "Continue")
                        .frame(maxWidth: .infinity)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(run.selectedBytes == 0)
                .animation(.snappy, value: run.selectedBytes)
                Button("Cancel", action: close)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        case .trashing, .deleting:
            let chosen = run.targets
            let done = chosen.filter {
                run.phase == .trashing ? ($0.status != .waiting && $0.status != .running) || $0.isCommand
                    : $0.status == .done || { if case .failed = $0.status { true } else { false } }($0)
            }.count
            ProgressView(value: Double(done), total: Double(max(1, chosen.count)))
                .animation(.snappy, value: done)
        case .staged:
            VStack(spacing: 8) {
                Button {
                    run.deleteForGood(env: model.agentEnv)
                } label: {
                    Text("Delete \(Fmt.size(run.pendingBytes)) for good")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(run.pendingBytes == 0)
                .help("Deletes only what this cleanup moved to the Trash, and clears the tool caches")
                Button("Keep in the Trash", action: close)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        case .done:
            Button("Done", action: close)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        case .failed:
            HStack {
                Button("Close", action: close)
                Spacer()
                Button("Try again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Seconds since the run began, ticking so the panel never looks frozen.
private struct Clock: View {
    let run: AgentRun

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            Text(String(format: "%.1f s", context.date.timeIntervalSince(run.startedAt)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

private struct PlanCard: View {
    @Bindable var item: PlanItem
    let editable: Bool
    let current: Bool
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            status
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.spec.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.size(item.bytes))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(item.spec.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = item.note, item.blocked == nil {
                    Label(note, systemImage: "hammer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let blocked = item.blocked {
                    Label(blocked, systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if case .failed(let message) = item.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: item.isCommand ? "terminal" : "trash")
                        Text(item.isCommand ? item.spec.command : where_)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(current ? 0.10 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(current ? 0.8 : 0), lineWidth: 1)
        )
        .opacity(item.blocked != nil || (!editable && !item.selected && item.status == .waiting) ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if editable, item.blocked == nil { item.selected.toggle() }
            reveal()
        }
        .help(item.paths.joined(separator: "\n"))
        .contextMenu {
            ForEach(item.paths, id: \.self) { path in
                Button("Reveal \((path as NSString).lastPathComponent) in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
        .animation(.snappy, value: item.status)
    }

    /// Where the folders are, shortest form.
    private var where_: String {
        let home = NSHomeDirectory()
        let shown = item.paths.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
        guard let first = shown.first else { return "" }
        return shown.count == 1 ? first : "\(first) +\(shown.count - 1)"
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .inTrash:
            Image(systemName: "trash.circle.fill")
                .foregroundStyle(.blue)
                .transition(.scale.combined(with: .opacity))
        case .skipped, .waiting:
            if item.status == .skipped {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.tertiary)
            } else {
                Toggle("", isOn: $item.selected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!editable || item.blocked != nil)
            }
        }
    }
}

/// A card-shaped placeholder that breathes while the plan is written.
private struct SkeletonCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .frame(height: 64)
            .phaseAnimator([0.4, 1.0]) { view, phase in
                view.opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

/// A soft light sweeping across live text.
private struct Shimmer: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.overlay {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    LinearGradient(
                        stops: [.init(color: .clear, location: t - 0.25),
                                .init(color: .white.opacity(0.55), location: t),
                                .init(color: .clear, location: t + 0.25)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .mask(content)
                }
            }
        } else {
            content
        }
    }
}

/// Installing or signing in, in a line the user can glance at.
private struct SetupProgress: View {
    let setup: AgentSetup
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch setup.step {
            case .installing, .signingIn:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(setup.step == .installing ? "Installing \(setup.kind.name)" : "Sign in to \(setup.kind.name)")
                            .font(.headline)
                            .modifier(Shimmer(active: true))
                        Text(setup.step == .installing ? "About 15 seconds, no password needed"
                             : "Finish in the browser window that just opened")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Cancel", action: cancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                HStack {
                    Button("Cancel", action: cancel)
                    Spacer()
                    Button("Try again", action: retry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .animation(.snappy, value: setup.step)
    }
}
