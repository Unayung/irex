import QuickLook
import SwiftUI

/// File paths as agents print them: "Wrote docs/report.md", "Saved ./shots/home.png:12",
/// "⏺ Read(src/app.swift)". A guess, not a parser.
enum FilePaths {
    private static let separators = Set(" \t\"'`()[]<>{},|⎿⏺│")
    /// Without a slash, only these count, so code such as `app.stream` doesn't.
    private static let known: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "pdf", "mp4", "mov", "md", "txt", "log", "csv",
        "json", "yaml", "yml", "toml", "html", "css", "js", "ts", "tsx", "py", "go", "rs", "swift", "c", "h",
        "cpp", "rb", "sh", "sql", "xml", "zip", "diff", "patch",
    ]

    /// Every path in a line, with the columns it covers (one Character per column).
    static func find(in line: String) -> [(columns: Range<Int>, path: String)] {
        let chars = Array(line)
        var found: [(Range<Int>, String)] = []
        var i = 0
        while i < chars.count {
            if separators.contains(chars[i]) { i += 1; continue }
            var j = i
            while j < chars.count && !separators.contains(chars[j]) { j += 1 }
            if let p = path(String(chars[i..<j])) { found.append((i..<j, p)) }
            i = j
        }
        return found
    }

    static func path(_ token: String) -> String? {
        var t = token
        while let last = t.last, ".,:;!?".contains(last) { t.removeLast() }
        if let r = t.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { t.removeSubrange(r) }
        guard t.count > 2, !t.contains("://") else { return nil }
        let ext = t.range(of: #"(?<=[^/.])\.([A-Za-z][A-Za-z0-9]{0,7})$"#, options: .regularExpression).map { String(t[$0].dropFirst()).lowercased() }
        let rooted = t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") || t.hasPrefix("../")
        if t.contains("/") {
            return ext != nil || (rooted && t.dropFirst().contains("/")) ? t : nil
        }
        return ext.map(known.contains) == true ? t : nil
    }

    #if DEBUG
    /// `-checkPaths YES` at launch: the cases above, asserted.
    static func selfCheck() {
        func paths(_ s: String) -> [String] { find(in: s).map(\.path) }
        assert(paths("Wrote docs/report.md.") == ["docs/report.md"])
        assert(paths("⏺ Read(src/app.swift)") == ["src/app.swift"])
        assert(paths("Saved ./shots/home.png:12:3, done") == ["./shots/home.png"])
        assert(paths("see /tmp/claude/scratch/out and https://x.com/a.png") == ["/tmp/claude/scratch/out"])
        assert(paths("app.stream e.g. v1.2 notes.md") == ["notes.md"])
        assert(paths("  2 + let x = 1") == [])
        assert(find(in: "ab docs/a.md").first?.columns == 3..<12)
    }
    #endif
}

extension TerminalModel {
    /// The screen's rows as text, one Character per column, each exactly the grid's width.
    private func screenRows() -> [[Character]] {
        frame().rows.map { cells in
            var line = [Character](repeating: " ", count: columns)
            for c in cells where line.indices.contains(c.x) { line[c.x] = c.text.first ?? " " }
            return line
        }
    }

    /// A row the terminal carried on to the next: written to its last column.
    private func wraps(_ row: [Character]) -> Bool { row.last.map { $0 != " " } ?? false }

    /// The file path drawn at a cell of the screen, if there is one, whole even where it wrapped.
    func path(atColumn column: Int, row: Int) -> String? {
        let rows = screenRows()
        guard rows.indices.contains(row) else { return nil }
        var first = row, last = row
        while first > 0 && wraps(rows[first - 1]) { first -= 1 }
        while last < rows.count - 1 && wraps(rows[last]) { last += 1 }
        let line = String(rows[first...last].joined())
        let at = (row - first) * columns + column
        return FilePaths.find(in: line).first { $0.columns.contains(at) }?.path
    }

    /// Every path on the screen, the latest first, each once; wrapped lines joined back up.
    func pathsOnScreen() -> [String] {
        var lines: [String] = [], current: [Character] = []
        for row in screenRows() {
            current += row
            if !wraps(row) { lines.append(String(current)); current = [] }
        }
        if !current.isEmpty { lines.append(String(current)) }
        var seen = Set<String>()
        return lines.reversed().flatMap { FilePaths.find(in: $0).map(\.path).reversed() }.filter { seen.insert($0).inserted }
    }
}

/// Quick Look over whatever is on screen: images, PDFs, video, text, with its own share and Done.
@MainActor
enum FilePreviewer {
    private final class Source: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
    private static var source: Source?   // the controller holds its data source weakly

    static func show(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let shown = top.presentedViewController { top = shown }
        let q = QLPreviewController()
        source = Source(url)
        q.dataSource = source
        top.present(q, animated: true)
    }
}

extension BlockStream {
    /// Fetches a file the pane's program mentioned and shows it, with a note while it comes.
    func preview(_ path: String) async {
        let name = (path as NSString).lastPathComponent
        noteFile("Opening \(name)…", failed: false)
        do {
            let url = try await download(path)
            noteFile(nil, failed: false)
            FilePreviewer.show(url)
        } catch {
            let note = "Couldn't open \(name): \(describe(error))"
            noteFile(note, failed: true)
            try? await Task.sleep(for: .seconds(4))
            if uploadNote == note { noteFile(nil, failed: false) }
        }
    }
}

/// The files the screen mentions, to open without aiming at small text.
struct ScreenFiles: View {
    let paths: [String]
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if paths.isEmpty {
                    ContentUnavailableView("No files on screen", systemImage: "doc.questionmark",
                                           description: Text("Paths an agent prints, such as docs/report.md, show up here."))
                } else {
                    List(paths, id: \.self) { path in
                        Button { onOpen(path) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(path)).font(.title3).foregroundStyle(.tint).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    // Colours, not .primary: in a button that would be the tint.
                                    Text((path as NSString).lastPathComponent).font(.body.weight(.medium)).foregroundStyle(Color.primary)
                                    if path.contains("/") {
                                        Text(path).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Files on Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func icon(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": "photo"
        case "mp4", "mov": "film"
        case "pdf": "doc.richtext"
        case "": "folder"
        default: "doc.text"
        }
    }
}
