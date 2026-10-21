#if canImport(SwiftUI)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The amiibo catalogue (names and series from AmiiboDB/Amiibo's file names; no amiibo data or keys are bundled).
struct AmiiboEntry: Decodable, Identifiable, Equatable {
    var name: String
    var series: String
    var rel: String
    var section: String
    var id: String? = nil
    var identity: String { rel }
}

private struct AmiiboCatalog: Decodable {
    var schema: Int
    var entries: [AmiiboEntry]
}

private struct AmiiboFile {
    var path: String
    var tokens: Set<String>
}

/// A separate amiibo menu: Tears of the Kingdom, Breath of the Wild, and the rest of the Nintendo lineup.
/// The player points it at their own .nfc folder; matching is by name (any folder layout), and any file can be
/// assigned to the selected entry. The UID is extracted from Flipper text dumps into a small binary dump that the
/// runtime reads, so both binary NTAG215 files and Flipper files work.
struct AmiiboSection: View {
    @EnvironmentObject var model: AppModel
    @State private var entries: [AmiiboEntry] = []
    @State private var files: [AmiiboFile] = []
    @State private var query = ""
    @State private var folder = ""
    @State private var selectedRel: String?
    @State private var selectedPath = ""

    private var totk: [AmiiboEntry] { filtered("totk") }
    private var botw: [AmiiboEntry] { filtered("botw") }
    private var other: [AmiiboEntry] { filtered("other") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Choose dumps folder…") { chooseFolder() }
                    .buttonStyle(.borderedProminent).tint(Theme.red)
                Button("Choose .nfc for selected…") { chooseFile() }
                    .disabled(selectedRel == nil)
                Text(folder.isEmpty ? "No folder chosen" : folder)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                TextField("Search amiibo", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Text("Switchy does not include amiibo data. Point this at your own dump folder (any layout; Flipper text "
                 + "or binary NTAG215 .bin files) and pick a tag; the runtime presents it as a virtual NFC tag. Amiibo IDs "
                 + "(character, series, model) are known for the Zelda entries here; other entries present their tag "
                 + "without character data. “Choose .nfc for selected…” assigns one file to the highlighted entry.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    group("Tears of the Kingdom", totk)
                    group("Breath of the Wild", botw)
                    group("Nintendo lineup", other)
                }
                .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 28)
        .onAppear(perform: load)
        .onChange(of: folder) { _, new in files = scan(new) }
    }

    private func group(_ title: String, _ list: [AmiiboEntry]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(title.uppercased())  ·  \(list.count)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.red)
                .padding(.top, 10).padding(.bottom, 2)
            ForEach(list, id: \.identity) { entry in row(entry) }
        }
    }

    private func row(_ entry: AmiiboEntry) -> some View {
        let path = matchPath(for: entry)
        return Button {
            selectedRel = entry.rel
            if let path { assign(entry, path: path) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13)).foregroundStyle(Theme.red).frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(entry.series).font(.system(size: 10)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                if let id = entry.id, !id.isEmpty {
                    Text(id).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.inkSecondary)
                }
                if path != nil {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                } else {
                    Text("no dump").font(.system(size: 10)).foregroundStyle(Theme.inkSecondary)
                }
                if selectedRel == entry.rel {
                    Image(systemName: "largecircle.fill.circle").font(.system(size: 13)).foregroundStyle(Theme.red)
                }
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selectedRel == entry.rel ? Theme.red.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(path == nil && selectedRel != entry.rel ? 0.75 : 1)
    }

    private func filtered(_ section: String) -> [AmiiboEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { $0.section == section &&
            (q.isEmpty || $0.name.lowercased().contains(q) || $0.series.lowercased().contains(q)) }
    }

    private func load() {
        let settings = model.settings?.settings
        folder = settings?["game"]?["amiibo_folder"]?.string ?? ""
        selectedPath = settings?["game"]?["amiibo_dump"]?.string ?? ""
        files = scan(folder)
        guard entries.isEmpty,
              let url = Bundle.module.url(forResource: "amiibo", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(AmiiboCatalog.self, from: data) else { return }
        entries = catalog.entries
    }

    // MARK: matching

    private func scan(_ root: String) -> [AmiiboFile] {
        guard !root.isEmpty else { return [] }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var out: [AmiiboFile] = []
        for case let found as URL in walk where ["nfc", "bin"].contains(found.pathExtension.lowercased()) {
            out.append(AmiiboFile(path: found.resolvingSymlinksInPath().path,
                                  tokens: tokens(found.deletingPathExtension().lastPathComponent)))
        }
        return out
    }

    private func tokens(_ text: String) -> Set<String> {
        let parts = text.lowercased().replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { !$0.isEmpty })
    }

    /// Series words that tell same-named figures apart (which "Link" this is).
    private func hints(_ series: String) -> Set<String> {
        var h = Set<String>()
        let s = series.lowercased()
        if s.contains("breath") { h.formUnion(["botw", "breath", "wild"]) }
        if s.contains("tears") { h.formUnion(["totk", "tears"]) }
        if s.contains("smash") { h.formUnion(["smash"]) }
        if s.contains("wind waker") || s.contains("30th") { h.formUnion(["wind", "waker", "30th", "anniversary"]) }
        if s.contains("twilight") { h.formUnion(["twilight"]) }
        if s.contains("skyward") { h.formUnion(["skyward"]) }
        if s.contains("majora") { h.formUnion(["majora"]) }
        if s.contains("awakening") { h.formUnion(["awakening"]) }
        return h
    }

    /// The best file whose name contains every word of the catalogue name. A same-named figure is only matched when
    /// its series words decide it, or when the name itself is unique.
    private func matchPath(for entry: AmiiboEntry) -> String? {
        let catalogueName = ((entry.rel as NSString).lastPathComponent as NSString).deletingPathExtension
        let want = tokens(catalogueName)
        guard !want.isEmpty else { return nil }
        let wanted = hints(entry.series)
        var candidates: [(path: String, score: Int)] = []
        for file in files where want.isSubset(of: file.tokens) {
            candidates.append((file.path, wanted.intersection(file.tokens).count * 10 - file.tokens.count))
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.score > $1.score }
        let bestName = ((candidates[0].path as NSString).lastPathComponent as NSString).deletingPathExtension
        let bestTokens = tokens(bestName)
        if candidates.count > 1 && wanted.intersection(bestTokens).isEmpty {
            return nil   // ambiguous and no series word to decide it
        }
        return candidates[0].path
    }

    private func assign(_ entry: AmiiboEntry, path: String) {
        guard let dump = normalisedDump(from: URL(fileURLWithPath: path), id: entry.id ?? "") else {
            model.message = "Could not read the UID from \(path). It should be a Flipper NFC file or a binary NTAG215 dump."
            return
        }
        selectedPath = dump
        model.setSettings(["game": .object(["amiibo_dump": .string(dump),
                                            "amiibo_id": .string(entry.id ?? ""),
                                            "amiibo_folder": .string(folder)])])
    }

    /// Flipper text dumps carry the UID on a "UID:" line; the runtime only needs the 7 UID bytes in the binary
    /// NTAG215 positions. Binary dumps are passed through unchanged.
    private func normalisedDump(from url: URL, id: String) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let head = String(data: data.prefix(24), encoding: .ascii) ?? ""
        if !head.hasPrefix("Filetype:") {
            return data.count >= 8 ? url.path : nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var uid: [UInt8] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("UID:") else { continue }
            uid = trimmed.dropFirst(4).split(separator: " ").compactMap { UInt8(String($0), radix: 16) }
            break
        }
        guard uid.count >= 7 else { return nil }
        var dump = [UInt8](repeating: 0, count: 540)
        dump[0] = uid[0]; dump[1] = uid[1]; dump[2] = uid[2]
        dump[4] = uid[3]; dump[5] = uid[4]; dump[6] = uid[5]; dump[7] = uid[6]
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchy/amiibo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (id.isEmpty ? url.deletingPathExtension().lastPathComponent : id) + ".nfc"
        let out = dir.appendingPathComponent(name)
        do { try Data(dump).write(to: out); return out.path } catch { return nil }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        panel.message = "Choose the folder holding your amiibo .nfc dumps"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
        files = scan(folder)
        model.setSettings(["game": .object(["amiibo_folder": .string(folder)])])
    }

    private func chooseFile() {
        guard let rel = selectedRel, let entry = entries.first(where: { $0.rel == rel }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use dump"
        panel.message = "Choose the .nfc dump for \(entry.name)"
        panel.allowedFileTypes = ["nfc", "NFC", "bin", "BIN"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        assign(entry, path: url.path)
    }
}
#endif
