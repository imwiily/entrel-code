import SwiftUI

/// Files changed in the project according to git, with the diff of the selected one.
struct GitChangesView: View {
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    @State private var changes: [GitChange]?
    @State private var selection: GitChange?
    @State private var diff: [DiffLine] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Alterações em \(directory.lastPathComponent)", systemImage: "plusminus.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Atualizar")
                Button("Fechar") { dismiss() }
                    .buttonStyle(.elevated)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(Theme.surfaceLowest)
            Rectangle().fill(Theme.divider).frame(height: 1)
            content
        }
        .background(Theme.canvas)
        .frame(minWidth: 900, minHeight: 560)
        .task { await reload() }
        .onChange(of: selection) { change in
            guard let change else { diff = []; return }
            let directory = directory
            Task {
                diff = await Task.detached { Git.diff(for: change, in: directory) }.value
            }
        }
    }

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let changes {
            if changes.isEmpty {
                Text("Nenhuma alteração.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(changes, selection: $selection) { change in
                        HStack {
                            Text(change.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(color(for: change))
                                .frame(width: 72, alignment: .leading)
                            Text(change.path).lineLimit(1).truncationMode(.head)
                        }
                        .tag(change)
                        .contextMenu {
                            Button("Abrir arquivo") { NSWorkspace.shared.open(directory.appendingPathComponent(change.path)) }
                            Button("Mostrar no Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([directory.appendingPathComponent(change.path)])
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Theme.surface)
                    .frame(minWidth: 260, idealWidth: 300)

                    diffView.frame(minWidth: 500)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.folder").font(.largeTitle).foregroundStyle(.secondary)
                Text("Esta pasta não está num repositório git.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var diffView: some View {
        if selection == nil {
            Text("Selecione um arquivo").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.indices, id: \.self) { index in
                        GitDiffLine(line: diff[index])
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 6)
            }
            .background(Theme.codeInset)
        }
    }

    private func color(for change: GitChange) -> Color {
        switch change.label {
        case "Novo", "Adicionado": return Theme.successText
        case "Apagado": return Theme.errorText
        default: return Theme.brand
        }
    }

    private func reload() async {
        loading = changes == nil
        let directory = directory
        let result = await Task.detached { Git.changes(in: directory) }.value
        changes = result
        loading = false
        if let selection, result?.contains(selection) != true { self.selection = nil }
        if self.selection == nil { self.selection = result?.first }
    }
}

private struct GitDiffLine: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : "")
                .frame(width: 18)
                .foregroundStyle(line.kind == .added ? Theme.success : line.kind == .removed ? Theme.error : Theme.textMuted)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .added ? Theme.successText : line.kind == .removed ? Theme.errorText
                                 : line.kind == .gap ? Theme.textMuted : Theme.hex(0xA5A5A9))
                .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.trailing, 12)
        .background(line.kind == .added ? Theme.addedBackground
                    : line.kind == .removed ? Theme.removedBackground
                    : line.kind == .gap ? Theme.surface : Color.clear)
    }
}
