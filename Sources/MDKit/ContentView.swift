import SwiftUI
import UniformTypeIdentifiers
import NetMDKit

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct ContentView: View {
    @EnvironmentObject var device: DeviceController
    @State private var selection = Set<Int>()
    @State private var showImporter = false
    @State private var showQueue = false
    @State private var showRipper = false
    @State private var dropTargeted = false
    @State private var renameTarget: RenameTarget?
    @State private var confirmErase = false
    @State private var confirmDelete = false

    enum RenameTarget: Identifiable {
        case disc, track(Track), group(DiscGroup)
        var id: String {
            switch self { case .disc: return "disc"; case .track(let t): return "t\(t.index)"; case .group(let g): return "g\(g.index)" }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if device.connected == nil {
                ConnectView()
            } else if let disc = device.disc {
                DiscView(disc: disc, selection: $selection, renameTarget: $renameTarget)
                Divider()
                CapacityBar(disc: disc, pendingSeconds: device.pendingDiscSeconds)
                TransportBar()
            } else {
                EmptyDiscView()
            }
        }
        .overlay(alignment: .center) {
            if let busy = device.busy, !device.isUploading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: .init(lineWidth: 3, dash: [8])).padding(6) } }
        .toolbar { toolbar }
        .navigationTitle(device.connected?.name ?? "MDKit")
        .navigationSubtitle(device.disc.map { $0.title.isEmpty ? "Untitled disc" : $0.title } ?? "")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFiles)) { _ in showImporter = true }
        .onReceive(NotificationCenter.default.publisher(for: .showRipper)) { _ in showRipper = true }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard device.connected != nil else { return false }
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in addFiles([url]) } }
                }
            }
            return true
        }
        .sheet(isPresented: $showQueue) { UploadQueueView() }
        .sheet(isPresented: $showRipper) { HomebrewRippingView() }
        .sheet(item: $renameTarget) { target in
            RenameSheet(target: target) { name in
                Task {
                    switch target {
                    case .disc: await device.renameDisc(name)
                    case .track(let t): await device.renameTrack(t, to: name)
                    case .group(let g): await renameGroup(g, to: name)
                    }
                }
            }
        }
        .alert("Error", isPresented: Binding(get: { device.errorMessage != nil }, set: { if !$0 { device.errorMessage = nil } })) {
            Button("OK") { device.errorMessage = nil }
        } message: { Text(device.errorMessage ?? "") }
        .confirmationDialog("Erase the entire disc?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase Disc", role: .destructive) { Task { await device.eraseDisc() } }
        } message: { Text("All tracks will be permanently removed.") }
        .confirmationDialog("Delete \(selection.count) track(s)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let s = Array(selection); selection = []
                Task { await device.deleteTracks(s) }
            }
        } message: { Text("This cannot be undone.") }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { showImporter = true } label: { Label("Add Audio", systemImage: "plus") }
                .help("Add audio files to the upload queue")
                .disabled(device.connected == nil)
            Button { showQueue = true } label: {
                Label("Upload Queue", systemImage: "square.and.arrow.up.on.square")
            }
            .badge(device.queue.filter { $0.state == .pending }.count)
            .disabled(device.connected == nil)
            Divider()
            Button { Task { await createGroup() } } label: { Label("Group Selected", systemImage: "folder.badge.plus") }
                .disabled(selection.isEmpty || device.disc == nil)
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
            Menu {
                Button("Rename Disc…") { renameTarget = .disc }
                Button("Refresh") { Task { await device.refresh() } }
                Button("Eject") { Task { await device.eject() } }
                Divider()
                Button("Erase Disc…", role: .destructive) { confirmErase = true }
            } label: { Label("Disc", systemImage: "opticaldisc") }
            .disabled(device.connected == nil || device.disc == nil)
            Button { showRipper = true } label: { Label("Homebrew Ripping…", systemImage: "waveform.badge.magnifyingglass") }
                .help("Download tracks via factory-mode sector recovery (non-MZ-RH1 decks)")
                .disabled(device.connected == nil || device.disc == nil)
        }
    }

    private func addFiles(_ urls: [URL]) {
        Task {
            await device.enqueue(urls)
            showQueue = true
        }
    }

    private func createGroup() async {
        guard let disc = device.disc else { return }
        let picked = disc.allTracks.filter { selection.contains($0.index) }
        guard !picked.isEmpty else { return }
        var groups = disc.groups.map { g -> DiscGroup in var g = g; g.tracks.removeAll { selection.contains($0.index) }; return g }
        groups.append(DiscGroup(index: groups.count, title: "New Group", fullWidthTitle: nil, tracks: picked))
        await device.commitLayout(groups.filter { !$0.tracks.isEmpty })
    }

    private func renameGroup(_ g: DiscGroup, to name: String) async {
        guard let disc = device.disc else { return }
        var groups = disc.groups
        if let i = groups.firstIndex(where: { $0.index == g.index }) { groups[i].title = name.isEmpty ? "Group" : name }
        await device.commitLayout(groups)
    }
}

// MARK: - Screens

struct ConnectView: View {
    @EnvironmentObject var device: DeviceController
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "opticaldisc").font(.system(size: 56)).foregroundStyle(.secondary)
            if device.attached.isEmpty {
                Text("Connect a NetMD recorder").font(.title2)
                Text("Plug the unit in with a USB cable and insert a disc.\nIt will be detected automatically.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                Text("Recorders found").font(.title2)
                ForEach(device.attached, id: \.self) { d in
                    Button(d.name) { Task { await device.connect(d) } }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            if !device.encoderAvailable {
                Label("ATRAC3 encoder not found — only SP uploads will work.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyDiscView: View {
    @EnvironmentObject var device: DeviceController
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.circle").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(device.status?.state == .readingTOC ? "Reading disc…" : "No disc").font(.title2)
            Text("Insert a MiniDisc into \(device.connected?.name ?? "the recorder").").foregroundStyle(.secondary)
            Button("Refresh") { Task { await device.refresh() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DiscView: View {
    @EnvironmentObject var device: DeviceController
    let disc: Disc
    @Binding var selection: Set<Int>
    @Binding var renameTarget: ContentView.RenameTarget?

    var body: some View {
        List(selection: $selection) {
            ForEach(disc.groups) { group in
                Section {
                    ForEach(group.tracks) { track in
                        TrackRow(track: track, playing: device.status?.track == track.index && device.status?.state == .playing)
                            .tag(track.index)
                            .contextMenu { menu(for: track, in: group) }
                            .onTapGesture(count: 2) { Task { await device.play(track: track.index) } }
                    }
                    .onMove { from, to in move(group: group, from: from, to: to) }
                } header: {
                    if let title = group.title {
                        HStack {
                            Image(systemName: "folder")
                            Text(title.isEmpty ? "Untitled group" : title).font(.headline)
                            Spacer()
                            Button("Rename") { renameTarget = .group(group) }.buttonStyle(.link)
                            Button("Ungroup") { Task { await ungroup(group) } }.buttonStyle(.link)
                        }
                    } else if disc.groups.count > 1 {
                        Text("Ungrouped").font(.headline)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder func menu(for track: Track, in group: DiscGroup) -> some View {
        Button("Play") { Task { await device.play(track: track.index) } }
        Button("Rename…") { renameTarget = .track(track) }
        let named = disc.groups.filter { $0.title != nil && $0.index != group.index }
        if !named.isEmpty || group.title != nil {
            Menu("Move to Group") {
                ForEach(named) { g in Button(g.title ?? "") { Task { await moveSelection(to: g.index, fallback: track) } } }
                if group.title != nil { Button("Ungrouped") { Task { await moveSelection(to: nil, fallback: track) } } }
            }
        }
    }

    private func picked(fallback: Track) -> [Track] {
        selection.contains(fallback.index) ? disc.allTracks.filter { selection.contains($0.index) } : [fallback]
    }

    private func moveSelection(to groupIndex: Int?, fallback: Track) async {
        let moving = picked(fallback: fallback)
        let ids = Set(moving.map(\.index))
        var groups = disc.groups.map { g -> DiscGroup in var g = g; g.tracks.removeAll { ids.contains($0.index) }; return g }
        if let gi = groupIndex, let i = groups.firstIndex(where: { $0.index == gi }) {
            groups[i].tracks += moving
        } else if let i = groups.firstIndex(where: { $0.title == nil }) {
            groups[i].tracks += moving
        } else {
            groups.insert(DiscGroup(index: 0, title: nil, fullWidthTitle: nil, tracks: moving), at: 0)
        }
        await device.commitLayout(groups)
    }

    private func move(group: DiscGroup, from: IndexSet, to: Int) {
        var groups = disc.groups
        guard let gi = groups.firstIndex(where: { $0.index == group.index }) else { return }
        groups[gi].tracks.move(fromOffsets: from, toOffset: to)
        Task { await device.commitLayout(groups) }
    }

    private func ungroup(_ group: DiscGroup) async {
        var groups = disc.groups.filter { $0.index != group.index }
        if let i = groups.firstIndex(where: { $0.title == nil }) {
            groups[i].tracks += group.tracks
        } else {
            groups.insert(DiscGroup(index: 0, title: nil, fullWidthTitle: nil, tracks: group.tracks), at: 0)
        }
        await device.commitLayout(groups)
    }
}

struct TrackRow: View {
    let track: Track
    let playing: Bool
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Text("\(track.index + 1)").monospacedDigit().foregroundStyle(.secondary).opacity(playing ? 0 : 1)
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor).opacity(playing ? 1 : 0)
            }
            .frame(width: 28, alignment: .trailing)
            Text(track.title.isEmpty ? "Untitled" : track.title)
                .foregroundStyle(track.title.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            if track.isProtected { Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Copy-protected") }
            Text(track.encoding.label + (track.channel == .mono ? " mono" : ""))
                .font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Text(formatDuration(track.seconds)).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

struct CapacityBar: View {
    let disc: Disc
    let pendingSeconds: Double

    var body: some View {
        let total = Double(max(disc.total, 1)) / 512.0
        let used = Double(disc.used) / 512.0
        let left = Double(disc.left) / 512.0
        VStack(alignment: .leading, spacing: 4) {
            GeometryBar(used: used / total, pending: min(pendingSeconds / total, 1 - used / total), over: pendingSeconds > left)
            HStack {
                Text("\(formatDuration(used)) used")
                Spacer()
                if pendingSeconds > 0 {
                    Text("+\(formatDuration(pendingSeconds)) queued").foregroundStyle(pendingSeconds > left ? .red : .secondary)
                    Spacer()
                }
                Text("\(formatDuration(left)) free (SP)")
            }
            .font(.caption).foregroundStyle(.secondary)
            if disc.writeProtected { Label("This disc is write-protected", systemImage: "lock").font(.caption).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct GeometryBar: View {
    let used: Double, pending: Double, over: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(width: g.size.width * used)
                    Rectangle().fill(over ? Color.red.opacity(0.6) : Color.accentColor.opacity(0.35)).frame(width: g.size.width * max(pending, 0))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(height: 8)
    }
}

struct TransportBar: View {
    @EnvironmentObject var device: DeviceController
    var body: some View {
        HStack(spacing: 18) {
            Button { Task { await device.transport { try $0.previousTrack() } } } label: { Image(systemName: "backward.fill") }
            Button { Task { await device.transport { try $0.play() } } } label: { Image(systemName: "play.fill") }
            Button { Task { await device.transport { try $0.pause() } } } label: { Image(systemName: "pause.fill") }
            Button { Task { await device.transport { try $0.stop() } } } label: { Image(systemName: "stop.fill") }
            Button { Task { await device.transport { try $0.nextTrack() } } } label: { Image(systemName: "forward.fill") }
            Spacer()
            if let s = device.status, let t = s.track, s.state == .playing || s.state == .paused {
                Text("Track \(t + 1)  \(formatDuration(s.elapsed ?? 0))").monospacedDigit().foregroundStyle(.secondary)
            } else if let s = device.status {
                Text(s.state.rawValue.capitalized).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless).imageScale(.large)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }
}

struct RenameSheet: View {
    let target: ContentView.RenameTarget
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @EnvironmentObject var device: DeviceController

    var title: String {
        switch target { case .disc: return "Rename Disc"; case .track: return "Rename Track"; case .group: return "Rename Group" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name).onSubmit(save).frame(width: 320)
            Text("Titles are stored on the disc in a limited character set; accents and unsupported symbols are simplified.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 320, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear {
            switch target {
            case .disc: name = device.disc?.title ?? ""
            case .track(let t): name = t.title
            case .group(let g): name = g.title ?? ""
            }
        }
    }

    private func save() { onSave(name); dismiss() }
}

struct UploadQueueView: View {
    @EnvironmentObject var device: DeviceController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Upload Queue").font(.title2.bold())
                Spacer()
                Picker("Default mode", selection: $device.defaultMode) {
                    ForEach(RecordingMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented).frame(width: 190).labelsHidden()
                .help("Mode used for newly added files")
            }
            if !device.encoderAvailable {
                Label("The ATRAC3 encoder is missing; LP2/LP4 uploads will fail.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            List {
                ForEach($device.queue) { $item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Title", text: $item.title).textFieldStyle(.plain).font(.body.weight(.medium))
                                .disabled(item.state != .pending)
                            Text(item.artist.isEmpty ? item.url.lastPathComponent : "\(item.artist) — \(item.url.lastPathComponent)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Picker("", selection: $item.mode) {
                            ForEach(RecordingMode.allCases) { m in Text(m.rawValue).tag(m) }
                        }
                        .labelsHidden().frame(width: 76).disabled(item.state != .pending)
                        Text(formatDuration(item.discSeconds)).monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                        StateView(state: item.state).frame(width: 130, alignment: .trailing)
                    }
                }
                .onDelete { device.queue.remove(atOffsets: $0) }
            }
            .frame(minHeight: 220)
            .overlay { if device.queue.isEmpty { Text("Drop audio files here or use ⌘O").foregroundStyle(.secondary) } }

            if let left = device.discSecondsLeft, device.pendingDiscSeconds > left {
                Label("Queued audio (\(formatDuration(device.pendingDiscSeconds))) exceeds the free space (\(formatDuration(left)) in SP).",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button("Clear Finished") { device.clearFinished() }.disabled(device.isUploading)
                Spacer()
                Button("Close") { dismiss() }
                if device.isUploading {
                    Button("Cancel Upload", role: .destructive) { device.cancelUploads() }
                } else {
                    Button("Upload \(device.queue.filter { $0.state == .pending }.count) Track(s)") { Task { await device.startUploads() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(device.queue.allSatisfy { $0.state != .pending } || device.disc?.writable == false)
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
    }
}

struct StateView: View {
    let state: UploadItem.State
    var body: some View {
        switch state {
        case .pending: Text("Waiting").foregroundStyle(.secondary)
        case .preparing(let s): HStack { ProgressView().controlSize(.small); Text(s).font(.caption) }
        case .sending(let f): ProgressView(value: f).frame(width: 110)
        case .done: Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled: Label("Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
        case .failed(let m): Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).help(m)
        }
    }
}
