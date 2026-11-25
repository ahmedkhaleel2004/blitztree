import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What the left panel lists.
enum ListMode: Hashable {
    case folders
    case largestFiles
}

/// The biggest files anywhere in the scan, flat. The engine picks them (the
/// same selection as the CLI's `largest_files`); this only shows them.
struct LargestFilesList: View {
    let model: ScanModel
    @State private var nodes: [Int] = []
    @State private var loadedFor: ObjectIdentifier?

    private nonisolated static let limit = 1000

    var body: some View {
        VStack(spacing: 0) {
            if let tree = model.tree {
                HStack {
                    Text("\(Fmt.num(UInt64(nodes.count))) largest files")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Largest first")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                if nodes.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        if loadedFor == ObjectIdentifier(tree) {
                            Image(systemName: "doc")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                            Text("No files")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(nodes, id: \.self) { node in
                                LargestFileRow(
                                    tree: tree,
                                    node: node,
                                    isSelected: model.selection == node
                                ) {
                                    model.reveal(node)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.tree.map(ObjectIdentifier.init)) {
            guard let tree = model.tree else {
                nodes = []
                loadedFor = nil
                return
            }
            let found = await Task.detached(priority: .userInitiated) {
                tree.largestFiles(limit: Self.limit)
            }.value
            guard !Task.isCancelled, model.tree === tree else { return }
            nodes = found
            loadedFor = ObjectIdentifier(tree)
        }
    }
}

private struct LargestFileRow: View {
    let tree: Tree
    let node: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let parent = Int(tree.parents[node])
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(nsImage: icon(for: tree.name(node)))
                    .resizable()
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tree.name(node))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if parent >= 0, parent < tree.count {
                        Text(tree.displayPath(parent))
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                Text(Fmt.size(tree.alloc[node]))
                    .font(.system(size: 11))
                    .monospacedDigit()
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static var iconCache: [String: NSImage] = [:]

    private func icon(for name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? "/plain" : ext
        if let hit = Self.iconCache[key] { return hit }
        let img = key == "/plain"
            ? NSWorkspace.shared.icon(for: .data)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        Self.iconCache[key] = img
        return img
    }
}
