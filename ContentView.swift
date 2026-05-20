import SwiftUI
import AppKit
import AVFoundation

struct ContentView: View {
    @StateObject private var engine = RecordingEngine.shared
    @ObservedObject private var store = RecordingStore.shared
    @AppStorage("isLiquidGlass") private var isLiquidGlass: Bool = false
    @AppStorage("themeColor")    private var themeColor:    ThemeColor = .default
    @AppStorage("defaultVideoPlayer") private var defaultVideoPlayer: String = ""
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @Environment(\.colorScheme) var colorScheme

    @State private var selectedRecordingID: UUID? = nil
    @State private var hoveredID: UUID? = nil
    @State private var searchText = ""
    @AppStorage("globalHotkey") private var globalHotkey: Int = 21

    private var hotkeyString: String {
        switch globalHotkey {
        case 19: return "⌘2"
        case 22: return "⌘6"
        default: return "⌘4"
        }
    }

    var body: some View {
        ZStack {
            // Background layer — matches BookmarkCleaner style
            backgroundLayer

            NavigationSplitView {
                sidebarView
            } detail: {
                detailView
            }
            .hideSidebarToggle()
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    NativeSearchField(text: $searchText, placeholder: T("Search recordings..."))
                        .frame(width: 300)
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)

            // Navigation Split View handles the UI


            // Saving overlay
            if case .saving = engine.state {
                savingOverlay
            }
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            if isLiquidGlass {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                    .ignoresSafeArea()
                if let color = themeColor.color {
                    color.opacity(0.10).ignoresSafeArea()
                }
                LinearGradient(colors: [.white.opacity(0.15), .clear, .black.opacity(0.06)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            } else {
                VisualEffectView(material: .menu, blendingMode: .behindWindow)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // App title
                HStack(spacing: 10) {
                    Image(systemName: "record.circle.fill")
                        .font(.title)
                        .foregroundStyle(themeColor.color ?? .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("Screen Recorder"))
                            .font(.system(.title3, design: .rounded).bold())
                        Menu {
                            Button(T("⌘ 2")) { setHotkey(19) }
                            Button(T("⌘ 4")) { setHotkey(21) }
                            Button(T("⌘ 6")) { setHotkey(22) }
                        } label: {
                            HStack(spacing: 4) {
                                Text(String(format: T("%@ to start / stop"), hotkeyString))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8))
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .fixedSize()
                    }
                    Spacer()

                }
                .padding(.bottom, 8)

                // Big record button
                RecordButton(engine: engine, themeColor: themeColor)

                Divider().opacity(0.15).padding(.vertical, 6)

                // Stats cards
                VStack(spacing: 10) {
                    StatCard(
                        icon: "film.stack",
                        label: T("Recordings"),
                        value: "\(store.recordings.count)",
                        color: themeColor.color ?? .blue
                    )
                    StatCard(
                        icon: "internaldrive",
                        label: T("Total Size"),
                        value: totalSizeFormatted,
                        color: themeColor.color ?? .purple
                    )
                    StatCard(
                        icon: "clock",
                        label: T("Total Duration"),
                        value: totalDurationFormatted,
                        color: themeColor.color ?? .orange
                    )
                }

                Spacer()
            }
            .padding(.horizontal, 18)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
    }

    // MARK: - Detail (file manager)

    private var detailView: some View {
        VStack(spacing: 0) {

            if filteredRecordings.isEmpty {
                emptyState
            } else {
                recordingsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredRecordings) { item in
                    RecordingRow(
                        item: item,
                        isSelected: selectedRecordingID == item.id,
                        isHovered: hoveredID == item.id,
                        themeColor: themeColor.color ?? .blue,
                        onSelect: { selectedRecordingID = item.id },
                        onOpen: { openRecording(item.url) },
                        onReveal: { engine.revealInFinder(item) },
                        onDelete: { engine.deleteRecording(item) }
                    )
                    .onHover { hoveredID = $0 ? item.id : nil }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: store.recordings.isEmpty ? "record.circle" : "magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(themeColor.color?.opacity(0.35) ?? Color.secondary.opacity(0.35))
            Text(store.recordings.isEmpty ? String(format: T("Press %@ or the button to start recording"), hotkeyString) : T("No results found"))
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(.secondary)
            Text(store.recordings.isEmpty ? String(format: T("Press %@ or the button to start recording"), hotkeyString) : T("Try a different search term"))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    // MARK: - Saving Overlay

    private var savingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial.opacity(0.85))
                .ignoresSafeArea()
            
            VStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(.primary)
                Text(T("Saving recording..."))
                    .font(.system(.title3, design: .rounded).bold())
                    .foregroundStyle(.primary)
            }
            .padding(32)
            .liquidGlass(isSelected: false, prominent: true, tint: nil, isHovered: false)
        }
    }

    // MARK: - Computed

    private var filteredRecordings: [RecordingItem] {
        let recordings = store.recordings
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return recordings }
        
        let tokens = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        return recordings.filter { item in
            tokens.allSatisfy { token in
                item.filename.localizedCaseInsensitiveContains(token) ||
                item.formattedDate.localizedCaseInsensitiveContains(token)
            }
        }
    }

    private var totalSizeFormatted: String {
        let total = store.recordings.reduce(0) { $0 + $1.fileSize }
        let mb = Double(total) / 1_000_000
        return mb < 1000 ? String(format: T("%.0f MB"), mb) : String(format: T("%.1f GB"), mb / 1000)
    }

    private var totalDurationFormatted: String {
        let total = store.recordings.reduce(0.0) { $0 + $1.duration }
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        if h > 0 { return String(format: T("%dh %dm"), h, m) }
        return String(format: T("%dm"), m)
    }

    private func openRecording(_ url: URL) {
        if defaultVideoPlayer.isEmpty {
            NSWorkspace.shared.open(url)
        } else {
            let appURL = URL(fileURLWithPath: defaultVideoPlayer)
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                if let error = error {
                    print("Error opening video with custom player: \(error)")
                    // Fallback to default if custom player fails
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func setHotkey(_ code: Int) {
        globalHotkey = code
        HotkeyManager.shared.register()
    }
}

// MARK: - RecordButton

struct RecordButton: View {
    @ObservedObject var engine: RecordingEngine
    let themeColor: ThemeColor
    @State private var isHovered = false

    @AppStorage("globalHotkey") private var globalHotkey: Int = 21

    private var hotkeyString: String {
        switch globalHotkey {
        case 19: return "⌘2"
        case 22: return "⌘6"
        default: return "⌘4"
        }
    }

    var isRecording: Bool {
        if case .recording = engine.state { return true }
        return false
    }

    var body: some View {
        Button {
            if isRecording {
                engine.toggleRecording()
            } else {
                RecordingControlStripManager.shared.showPanel()
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.red : (themeColor.color ?? .red))
                        .frame(width: 14, height: 14)
                    if isRecording {
                        Circle()
                            .fill(Color.red.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .scaleEffect(isRecording ? 1.4 : 1.0)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isRecording)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isRecording ? T("Stop Recording") : T("Start Recording"))
                        .font(.system(.body, design: .rounded).bold())
                    if isRecording {
                        Text(engine.elapsedFormatted)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    } else {
                        Text(String(format: T("%@ shortcut"), hotkeyString))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isRecording
                          ? Color.red.opacity(0.18)
                          : (isHovered ? (themeColor.color ?? .red).opacity(0.15) : Color.primary.opacity(0.07)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isRecording ? Color.red.opacity(0.4) : (themeColor.color ?? .red).opacity(0.25), lineWidth: 1.2)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
    }
}

// MARK: - StatCard

struct StatCard: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 28)
            Text(label)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded).bold())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlass(tint: color, isHovered: false) // Always show base glass
    }
}

// MARK: - VideoThumbnailView

/// A simple actor that caches generated thumbnails so we don't hit disk on every redraw.
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var store: [URL: NSImage] = [:]

    func image(for url: URL) -> NSImage? { store[url] }
    func set(_ image: NSImage, for url: URL) { store[url] = image }
}

struct VideoThumbnailView: View {
    let url: URL
    let accentColor: Color
    let onOpen: () -> Void

    @State private var thumbnail: NSImage? = nil
    @State private var isLoading = true
    @State private var isHovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accentColor.opacity(0.12))

            if let img = thumbnail {
                let isPortrait = img.size.width > 0 &&
                    (img.size.height / img.size.width) > (40.0 / 64.0)

                ZStack {
                    // Black background — only visible when pillarboxing
                    Color.black
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if isPortrait {
                        // Vertical video: fit fully, black bars on sides
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 40)
                    } else {
                        // Landscape / square: fill and center-crop
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 40)
                            .clipped()
                    }
                }
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity.animation(.easeIn(duration: 0.25)))
            } else if isLoading {
                // Shimmer placeholder
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(accentColor.opacity(0.18), lineWidth: 1)
                    )
                Image(systemName: "film")
                    .font(.system(size: 16))
                    .foregroundStyle(accentColor.opacity(0.35))
            } else {
                // Generation failed — fallback icon
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(accentColor.opacity(0.55))
            }

            // Play overlay on hover
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.38))
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.75))
                        .offset(x: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .scaleEffect(isHovering ? 1.04 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture { onOpen() }
        .pointingHandCursor(active: isHovering)
        .task(id: url) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        // Check cache first
        if let cached = await ThumbnailCache.shared.image(for: url) {
            thumbnail = cached
            isLoading = false
            return
        }

        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 128, height: 80)

        do {
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            let (cgImage, _) = try await gen.image(at: time)
            let img = NSImage(cgImage: cgImage, size: .zero)
            await ThumbnailCache.shared.set(img, for: url)
            thumbnail = img
        } catch {
            // first frame fallback
            let time = CMTime.zero
            if let result = try? await gen.image(at: time) {
                let img = NSImage(cgImage: result.image, size: .zero)
                await ThumbnailCache.shared.set(img, for: url)
                thumbnail = img
            }
        }
        isLoading = false
    }
}

// MARK: - RecordingRow

struct RecordingRow: View {
    let item: RecordingItem
    let isSelected: Bool
    let isHovered: Bool
    let themeColor: Color
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Real video thumbnail — click to open
            VideoThumbnailView(url: item.url, accentColor: themeColor, onOpen: onOpen)
                .frame(width: 64, height: 40)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename
                    .replacingOccurrences(of: ".mp4", with: "")
                    .replacingOccurrences(of: "Recording ", with: ""))
                    .font(.system(.subheadline, design: .rounded).bold())
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(item.formattedDuration, systemImage: "clock")
                    Label(item.formattedSize, systemImage: "internaldrive")
                }
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Date
            Text(item.formattedDate)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.tertiary)

            // Action buttons (show on hover/select)
            if isHovered || isSelected {
                HStack(spacing: 6) {
                    IconButton(icon: "folder", color: themeColor, action: onReveal)
                    IconButton(icon: "trash", color: .red, action: onDelete)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlass(isSelected: isSelected, prominent: false, tint: themeColor, isHovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { onSelect() }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        .contextMenu {
            Button { onOpen() }   label: { Label(T("Open"), systemImage: "play.fill") }
            Button { onReveal() } label: { Label(T("Reveal in Finder"), systemImage: "folder") }
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label(T("Delete"), systemImage: "trash") }
        }
    }
}

// MARK: - IconButton

struct IconButton: View {
    let icon: String
    let color: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(.caption, design: .rounded).bold())
                .foregroundStyle(isHovered ? color : .secondary)
                .frame(width: 28, height: 28)
                .background(isHovered ? color.opacity(0.12) : Color.clear)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - View Extensions

extension View {
    @ViewBuilder
    func hideSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }

    /// Shows a pointing-hand cursor while `active` is true.
    func pointingHandCursor(active: Bool) -> some View {
        self.onContinuousHover { phase in
            switch phase {
            case .active:
                if active { NSCursor.pointingHand.push() }
            case .ended:
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Native Search Field

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholder
        searchField.delegate = context.coordinator
        searchField.bezelStyle = .roundedBezel
        searchField.controlSize = .regular // More compatible with toolbar height
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            if let searchField = obj.object as? NSSearchField {
                text = searchField.stringValue
            }
        }
    }
}
