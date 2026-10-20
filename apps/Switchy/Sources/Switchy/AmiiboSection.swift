#if canImport(SwiftUI)
import AppKit
import SwiftUI

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

/// A separate amiibo menu: Tears of the Kingdom, Breath of the Wild, and the rest of the Nintendo lineup.
/// The player points it at their own dump folder (AmiiboDB's “Amiibo NFC” folder or any folder of .nfc files);
/// the chosen dump is stored in the game settings for the runtime's NFC side.
struct AmiiboSection: View {
    @EnvironmentObject var model: AppModel
    @State private var entries: [AmiiboEntry] = []
    @State private var query = ""
    @State private var folder = ""
    @State private var have: Set<String> = []
    @State private var selected = ""
    @State private var selectedID = ""

    private var totk: [AmiiboEntry] { filtered("totk") }
    private var botw: [AmiiboEntry] { filtered("botw") }
    private var other: [AmiiboEntry] { filtered("other") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Choose dumps folder…") { chooseFolder() }
                    .buttonStyle(.borderedProminent).tint(Theme.red)
                Text(folder.isEmpty ? "No folder chosen — scan for your .nfc dumps" : folder)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                TextField("Search amiibo", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
            Text("Switchy does not include amiibo data. Point this at your own dump folder (for example the "
                 + "AmiiboDB “Amiibo NFC” folder) and pick a tag; the runtime presents it as a virtual NFC tag. Amiibo "
                 + "IDs (character, series, model) are known for the Zelda entries here; other entries still present "
                 + "their tag, without character data.")
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
        .onChange(of: folder) { _, new in have = scan(new) }
        .onChange(of: selected) { _, new in
            guard !new.isEmpty else { return }
            model.setSettings(["game": ["amiibo_dump": .string(new), "amiibo_id": .string(selectedID),
                                        "amiibo_folder": .string(folder)]])
        }
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
        let path = folder.isEmpty ? "" : folder + "/" + entry.rel
        let present = have.contains(entry.rel)
        return Button {
            guard present else { return }
            selected = path
            selectedID = entry.id ?? ""
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13)).foregroundStyle(Theme.red).frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(entry.series).font(.system(size: 10)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                if present {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                } else {
                    Text("no dump").font(.system(size: 10)).foregroundStyle(Theme.inkSecondary)
                }
                if selected == path && !path.isEmpty {
                    Image(systemName: "largecircle.fill.circle").font(.system(size: 13)).foregroundStyle(Theme.red)
                }
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected == path && !path.isEmpty ? Theme.red.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!present)
        .opacity(present ? 1 : 0.55)
    }

    private func filtered(_ section: String) -> [AmiiboEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { $0.section == section &&
            (q.isEmpty || $0.name.lowercased().contains(q) || $0.series.lowercased().contains(q)) }
    }

    private func load() {
        let settings = model.settings?.settings
        folder = settings?["game"]?["amiibo_folder"]?.string ?? ""
        selected = settings?["game"]?["amiibo_dump"]?.string ?? ""
        selectedID = settings?["game"]?["amiibo_id"]?.string ?? ""
        have = scan(folder)
        guard entries.isEmpty,
              let url = Bundle.module.url(forResource: "amiibo", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(AmiiboCatalog.self, from: data) else { return }
        entries = catalog.entries
    }

    /// Relative .nfc paths under the chosen folder; a leading “Amiibo NFC/” is dropped so the repository root works too.
    private func scan(_ root: String) -> Set<String> {
        guard !root.isEmpty else { return [] }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var out = Set<String>()
        for case let found as URL in walk where found.pathExtension.lowercased() == "nfc" {
            var rel = found.resolvingSymlinksInPath().path
            if rel.hasPrefix(base.path + "/") { rel.removeFirst(base.path.count + 1) }
            if rel.hasPrefix("Amiibo NFC/") { rel.removeFirst("Amiibo NFC/".count) }
            out.insert(rel)
        }
        return out
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
        have = scan(folder)
        model.setSettings(["game": ["amiibo_folder": .string(folder)]])
    }
}
#endif
