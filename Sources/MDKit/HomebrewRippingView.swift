import SwiftUI
import UniformTypeIdentifiers
import NetMDKit

/// "Homebrew mode ripping" — pulls raw track data straight out of factory mode on decks that
/// don't support the standard NetMD download command (i.e. everything except the MZ-RH1/M200).
/// Needs no modification to the player: it's all done through RAM-only patches that undo
/// themselves on a power cycle.
struct HomebrewRippingView: View {
    @EnvironmentObject var device: DeviceController
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<Int>()
    @State private var destination: URL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    @State private var showFolderPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if device.ripItems.isEmpty {
                trackPicker
            } else {
                progressList
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .task { await device.prepareRipping() }
    }

    @ViewBuilder private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Homebrew Mode Ripping").font(.title2.bold())
                Text("Reads tracks directly from the player's memory via factory mode — works on decks without a standard download command.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        readinessBanner
    }

    @ViewBuilder private var readinessBanner: some View {
        switch device.ripperReadiness {
        case .unknown:
            EmptyView()
        case .checking:
            Label("Checking compatibility…", systemImage: "hourglass").font(.callout).foregroundStyle(.secondary)
        case .ready(let version):
            Label("Ready — firmware \(version)", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
        case .unavailable(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Not available on this unit", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Try Again") { Task { device.ripperReadiness = .unknown; await device.prepareRipping() } }
                    .font(.caption)
            }
        }
    }

    @ViewBuilder private var trackPicker: some View {
        let tracks = device.disc?.allTracks ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tracks").font(.headline)
                Spacer()
                Button(selection.count == tracks.count ? "Deselect All" : "Select All") {
                    selection = selection.count == tracks.count ? [] : Set(tracks.map(\.index))
                }
                .font(.caption)
            }
            Toggle("Skip ATRAC validity check (diagnostic)", isOn: $device.skipAtracValidation)
                .toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
                .help("Reads straight through without the frame-validity safety gate, so a run doesn't abort on the first sector that fails it. Output may contain glitches from positions that genuinely were bad — use this to see how far a track gets, not for a final rip.")
            List(tracks, selection: $selection) { track in
                HStack {
                    Text("\(track.index + 1). \(track.title.isEmpty ? "Untitled" : track.title)")
                    Spacer()
                    Text(track.encoding.label).font(.caption).foregroundStyle(.secondary)
                    Text(formatDuration(track.seconds)).monospacedDigit().font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                }
                .tag(track.index)
            }
        }
    }

    @ViewBuilder private var progressList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ripping \(device.ripItems.count) Track(s)").font(.headline)
            List(device.ripItems) { item in
                HStack {
                    Text(item.title).lineLimit(1)
                    Spacer()
                    RipStateView(state: item.state)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if device.ripItems.isEmpty {
                Button("Choose Folder…") { showFolderPicker = true }
                Text(destination.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Close") { dismiss() }
            if device.isRipping {
                Button("Cancel", role: .destructive) { device.cancelRipping() }
            } else if !device.ripItems.isEmpty {
                Button("Rip More…") { device.ripItems = [] }
            } else {
                Button("Start Ripping (\(selection.count))") {
                    Task { await device.startRipping(selection.sorted(), to: destination) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || !isReady)
            }
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { destination = url }
        }
    }

    private var isReady: Bool {
        if case .ready = device.ripperReadiness { return true }
        return false
    }
}

struct RipStateView: View {
    let state: RipItem.State
    var body: some View {
        switch state {
        case .pending: Text("Waiting").foregroundStyle(.secondary).font(.caption)
        case .downloading(let f): ProgressView(value: f).frame(width: 110)
        case .done: Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .cancelled: Label("Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary).font(.caption)
        case .failed(let m): Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption).help(m)
        }
    }
}
