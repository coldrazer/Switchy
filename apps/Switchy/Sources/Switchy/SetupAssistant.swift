#if canImport(SwiftUI)
import AppKit
import MNGCore
import SwiftUI

/// Welcome → Detection → Background build → Ready. The one decision is which game file; everything else is found.
struct SetupAssistant: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var initialFiles: [URL]

    enum Stage { case welcome, detection, building, ready }
    @State private var stage: Stage = .welcome
    @State private var files: [URL] = []
    @State private var detection: Detection?
    @State private var keys: String?
    @State private var problem: String?
    @State private var jobId: String?
    @State private var dropTargeted = false

    private var job: Job? { model.jobs.first { $0.id == jobId } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch stage {
                case .welcome: welcome
                case .detection: detectionView
                case .building: buildingView
                case .ready: readyView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
        .frame(width: 760, height: 560)
        .background(Theme.panelBackground)
        .environment(\.colorScheme, .light)
        .onAppear { if !initialFiles.isEmpty { add(initialFiles) } }
        .onChange(of: job?.status) { _, status in if status == "succeeded" { stage = .ready } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { index in
                let title = ["Welcome", "Your game", "Building", "Ready"][index]
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(index <= stageIndex ? Color.white : Color.white.opacity(0.35))
                        Text("\(index + 1)").font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(index <= stageIndex ? Theme.red : .white)
                    }
                    .frame(width: 26, height: 26)
                    Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
                if index < 3 { Rectangle().fill(.white.opacity(0.4)).frame(height: 2) }
            }
            Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).padding(.leading, 8)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(Theme.red)
    }

    private var stageIndex: Int {
        switch stage {
        case .welcome: return 0
        case .detection: return 1
        case .building: return 2
        case .ready: return 3
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 64)).foregroundStyle(Theme.red)
            Text("Play your own copy, natively").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
            Text("Point at the game file you dumped from your console. This Mac turns it into a native app in the "
                 + "background — about twenty minutes the first time — and tells you when it is ready. "
                 + "Nothing from the game leaves this Mac.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.inkSecondary).frame(maxWidth: 560)
            dropZone
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc.fill").font(.system(size: 34)).foregroundStyle(Theme.red)
            Text("Drop the game (.xci or .nsp), an update and your prod.keys here")
                .font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Theme.ink)
            Button("Choose files…") { choose() }.buttonStyle(.borderedProminent).tint(Theme.red)
        }
        .frame(maxWidth: .infinity).frame(height: 170)
        .background(RoundedRectangle(cornerRadius: 18).fill(dropTargeted ? Theme.red.opacity(0.08) : Color(hex: 0xF6F7F9)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.red.opacity(dropTargeted ? 1 : 0.4),
                                                                 style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { dropTargeted = $0 }
    }

    private var detectionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Here is what was found").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
            FoundRow(title: "Game", value: detection?.base, missing: "No base game (XCI or NSP) yet")
            FoundRow(title: "Update", value: detection?.update, missing: "None (optional: 1.1.2, 1.2.1 or 1.4.3)", optional: true)
            FoundRow(title: "Keys", value: keys, missing: "No prod.keys found: drop it or choose it")
            if let base = detection?.base, let file = detection?.files.first(where: { $0.path == base }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: file.supported == false ? "xmark.octagon.fill" : "checkmark.seal.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(file.supported == false ? Theme.red : .green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.game ?? file.title ?? (file.path as NSString).lastPathComponent)
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text(statusLine(file)).font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer()
                    }
                    if let reason = file.reason {
                        Text(reason).font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(file.supported == false ? Theme.red.opacity(0.07) : Color.green.opacity(0.10)))
            }
            ForEach(detection?.files.filter { $0.note != nil } ?? [], id: \.path) { file in
                Label("\((file.path as NSString).lastPathComponent): \(file.note ?? "")", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.octagon.fill").foregroundStyle(Theme.red).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Button("Add files…") { choose() }
                Spacer()
                Button {
                    Task { await start() }
                } label: { Label("Build in the background", systemImage: "hammer.fill").padding(.horizontal, 8) }
                    .buttonStyle(.borderedProminent).tint(Theme.red).controlSize(.large)
                    .disabled(detection?.base == nil || keys == nil || detection?.supported == false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
    }

    private var buildingView: some View {
        VStack(spacing: 22) {
            ProgressRing(value: job?.progress ?? 0, lineWidth: 14, tint: Theme.red)
                .environment(\.colorScheme, .dark)
                .frame(width: 150, height: 150)
                .background(Circle().fill(Theme.card))
            Text(job?.currentTitle ?? (job?.status == "queued" ? "Waiting for another build to finish" : "Starting"))
                .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
            if let line = model.logs[jobId ?? ""]?.last {
                Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.inkSecondary).lineLimit(2)
            }
            if job?.status == "failed" || job?.status == "cancelled" {
                Label(job?.error ?? "The build stopped.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(Theme.red).textSelection(.enabled)
                HStack {
                    Button("Show details") { dismiss(); model.panel = .builds }
                    Button("Try again") { Task { await start() } }.buttonStyle(.borderedProminent).tint(Theme.red)
                }
            } else {
                Text("You can close this window, or quit the app: the build keeps going and the game menu shows it.")
                    .font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                Button("Close") { dismiss() }
            }
        }
    }

    private var readyView: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 72)).foregroundStyle(.green)
            Text("Ready to play").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
            Text(job?.result?.app ?? "").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
            PlayButton(title: "PLAY NOW") {
                if let path = job?.result?.app, let app = model.library.first(where: { $0.path == path }) { model.play(app) }
                dismiss()
            }
            .frame(width: 320)
        }
    }

    // MARK: actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.message = "Choose the game file, an optional update, and your prod.keys"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        files = Array(Set(files + urls)).sorted { $0.path < $1.path }
        problem = nil
        Task {
            do {
                let found = try await model.detect(files)
                detection = found
                keys = found.keys ?? keys
                stage = .detection
            } catch {
                problem = (error as? AgentError)?.message ?? error.localizedDescription
                stage = .detection
            }
        }
    }

    private func statusLine(_ file: GameFile) -> String {
        var parts: [String] = []
        if let id = file.titleId { parts.append(id) }
        switch file.supported {
        case .some(false): parts.append("not supported by this build")
        case .some(true): parts.append("supported")
        default: parts.append("title not in the file name; the build identifies it by content")
        }
        return parts.joined(separator: " · ")
    }

    private func start() async {
        guard let base = detection?.base else { return }
        guard detection?.supported != false else {
            problem = detection?.reason ?? "This game is not supported by this build."
            return
        }
        guard model.hasRoomForBuild(path: base) else {
            problem = "This build needs about 25 GB free next to the game file; there is not enough room."
            return
        }
        problem = nil
        do {
            let job = try await model.build(game: base, update: detection?.update, keys: keys)
            jobId = job.id
            stage = .building
        } catch {
            problem = (error as? AgentError)?.message ?? error.localizedDescription
            stage = .detection
        }
    }
}

struct FoundRow: View {
    var title: String
    var value: String?
    var missing: String
    var optional = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: value != nil ? "checkmark.circle.fill" : optional ? "circle.dashed" : "exclamationmark.circle.fill")
                .foregroundStyle(value != nil ? .green : optional ? Theme.inkSecondary : .orange)
                .font(.system(size: 20))
            Text(title).font(.system(size: 15, weight: .semibold)).frame(width: 70, alignment: .leading)
            Text(value.map { ($0 as NSString).lastPathComponent } ?? missing)
                .foregroundStyle(value != nil ? Theme.ink : Theme.inkSecondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF6F7F9)))
    }
}
#endif
