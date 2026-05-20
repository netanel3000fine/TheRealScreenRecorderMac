import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    // MARK: - App Storage
    @AppStorage("isLiquidGlass")      private var isLiquidGlass: Bool      = false
    @AppStorage("themeColor")         private var themeColor:    ThemeColor = .default
    @AppStorage("saveLocation")       private var saveLocation:  String     = ""
    @AppStorage("showCountdown")      private var showCountdown: Bool       = true
    @AppStorage("launchAtLogin")      private var launchAtLogin: Bool       = true
    @AppStorage("defaultVideoPlayer") private var defaultVideoPlayer: String     = ""
    @AppStorage("autoOpenRecording")  private var autoOpenRecording:  Bool       = false
    @AppStorage("controlStripStyle")  private var controlStripStyle: ControlStripStyle = .standard
    @AppStorage("showQuitWarning")    private var showQuitWarning:    Bool       = true
    @AppStorage("globalHotkey")       private var globalHotkey:       Int        = 21
    @AppStorage("appLanguage")        private var appLanguage:        String     = "en"
    @AppStorage("resolutionScale")    private var resolutionScale:    Int        = 100
    @AppStorage("videoFrame")         private var videoFrame:         Bool       = false

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                
                // Appearance Section
                SettingsSection(title: T("Appearance"), icon: "paintpalette.fill") {
                    VStack(spacing: 0) {
                        SettingsToggle(
                            title: "Liquid Glass interface",
                            subtitle: "Enable premium transparency and effects",
                            icon: "sparkles",
                            isOn: $isLiquidGlass
                        )
                        
                        Divider().padding(.horizontal, 12)
                        
                        SettingsControlRow(
                            title: "Control Strip Style",
                            subtitle: controlStripStyle == .standard ? "Standard — compact UI" :
                                      controlStripStyle == .large ? "Large — easier to click" :
                                      "Notch — Dynamic Island style",
                            icon: "uiwindow.split.2x1"
                        ) {
                            Picker("", selection: $controlStripStyle) {
                                Text(T("Standard")).tag(ControlStripStyle.standard)
                                Text(T("Large")).tag(ControlStripStyle.large)
                                Text(T("Notch")).tag(ControlStripStyle.notch)
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .frame(width: 110)
                        }
                        
                        Divider().padding(.horizontal, 12)
                        
                        SettingsControlRow(
                            title: "Theme Color",
                            subtitle: "Primary accent for the interface",
                            icon: "drop.fill"
                        ) {
                            ThemeColorPicker(selection: $themeColor)
                        }
                    }
                }

                // Recording Section
                SettingsSection(title: T("Recording"), icon: "record.circle.fill") {
                    VStack(spacing: 0) {
                        SettingsToggle(
                            title: "Show Countdown",
                            subtitle: "3-second countdown before recording starts",
                            icon: "timer",
                            isOn: $showCountdown
                        )
                        
                        Divider().padding(.horizontal, 12)
                        
                        SettingsControlRow(
                            title: "Resolution",
                            subtitle: resolutionScale == 100
                                ? "Native — full pixel resolution"
                                : resolutionScale == 75
                                    ? "75% — reduced file size"
                                    : "50% — smallest file size",
                            icon: "video.badge.checkmark"
                        ) {
                            ResolutionPicker(selection: $resolutionScale)
                        }
                        
                        Divider().padding(.horizontal, 12)

                        SettingsToggle(
                            title: "Video Frame",
                            subtitle: "Add a thin white border around the recorded video",
                            icon: "rectangle.dashed",
                            isOn: $videoFrame
                        )

                        Divider().padding(.horizontal, 12)
                        
                        SettingsToggle(
                            title: "Auto-open Recording",
                            subtitle: "Automatically open the video after saving",
                            icon: "play.circle",
                            isOn: $autoOpenRecording
                        )
                        
                        Divider().padding(.horizontal, 12)
                        
                        SettingsToggle(
                            title: "Launch at Login",
                            subtitle: "Start in menu bar when you log in",
                            icon: "arrow.up.right.square",
                            isOn: Binding(
                                get: { launchAtLogin },
                                set: { newValue in
                                    launchAtLogin = newValue
                                    toggleLoginItem(newValue)
                                }
                            )
                        )
                        
                        Divider().padding(.horizontal, 12)
                        
                        SettingsControlRow(
                            title: "Save Location",
                            subtitle: saveLocation.isEmpty
                                ? "~/Movies/Screen Recordings"
                                : saveLocation,
                            icon: "folder"
                        ) {
                            Button(T("Change")) { chooseSaveLocation() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        
                        Divider().padding(.horizontal, 12)
                        
                        SettingsControlRow(
                            title: "Default Video Player",
                            subtitle: defaultVideoPlayer.isEmpty
                                ? "System Default"
                                : URL(fileURLWithPath: defaultVideoPlayer).deletingPathExtension().lastPathComponent,
                            icon: "play.rectangle"
                        ) {
                            Menu {
                                Button(T("System Default")) { defaultVideoPlayer = "" }
                                Button(T("QuickTime Player")) { defaultVideoPlayer = "/System/Applications/QuickTime Player.app" }
                                if FileManager.default.fileExists(atPath: "/Applications/VLC.app") {
                                    Button(T("VLC")) { defaultVideoPlayer = "/Applications/VLC.app" }
                                }
                                if FileManager.default.fileExists(atPath: "/Applications/IINA.app") {
                                    Button(T("IINA")) { defaultVideoPlayer = "/Applications/IINA.app" }
                                }
                                Divider()
                                Button(T("Choose Application...")) { chooseVideoPlayer() }
                            } label: {
                                Text(defaultVideoPlayer.isEmpty ? "System Default" : URL(fileURLWithPath: defaultVideoPlayer).deletingPathExtension().lastPathComponent)
                            }
                            .controlSize(.small)
                            .frame(width: 130)
                        }
                    }
                }

                // Shortcut & App Section
                SettingsSection(title: T("Shortcut & App"), icon: "command") {
                    VStack(spacing: 0) {
                        SettingsControlRow(
                            title: "Global Hotkey",
                            subtitle: "Start/stop recording from anywhere",
                            icon: "keyboard"
                        ) {
                            Picker("", selection: $globalHotkey) {
                                Text(T("⌘ 2")).tag(19)
                                Text(T("⌘ 4")).tag(21)
                                Text(T("⌘ 6")).tag(22)
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .frame(width: 80)
                            .onChange(of: globalHotkey) { _, _ in
                                HotkeyManager.shared.register()
                            }
                        }
                        
                        Divider().padding(.horizontal, 12)
                        
                        SettingsToggle(
                            title: "Quit Warning",
                            subtitle: "Show confirmation prompt when quitting (⌘Q)",
                            icon: "exclamationmark.triangle",
                            isOn: $showQuitWarning
                        )
                    }
                }

                // Language Section
                SettingsSection(title: T("Language / שפה"), icon: "globe") {
                    VStack(spacing: 0) {
                        SettingsControlRow(
                            title: "Language",
                            subtitle: "Select the application language",
                            icon: "character.bubble"
                        ) {
                            HStack(spacing: 8) {
                                Button { appLanguage = "en" } label: {
                                    Text("EN")
                                        .font(.system(size: 11, weight: .bold))
                                        .frame(width: 32, height: 24)
                                        .background(appLanguage == "en" ? (themeColor.color ?? Color.accentColor) : Color.primary.opacity(0.1))
                                        .foregroundColor(appLanguage == "en" ? .white : .primary)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)

                                Button { appLanguage = "he" } label: {
                                    Text("HE")
                                        .font(.system(size: 11, weight: .bold))
                                        .frame(width: 32, height: 24)
                                        .background(appLanguage == "he" ? (themeColor.color ?? Color.accentColor) : Color.primary.opacity(0.1))
                                        .foregroundColor(appLanguage == "he" ? .white : .primary)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // About Section
                VStack(spacing: 8) {
                    HStack {
                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text("Version \(version)")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                }

            }
            .padding(24)
        }
        .frame(width: 520, height: 680)
        .background {
            if isLiquidGlass {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                    .ignoresSafeArea()
            } else {
                VisualEffectView(material: .menu, blendingMode: .behindWindow)
                    .ignoresSafeArea()
            }
        }
        .background(WindowAccessor())
    }

    private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            saveLocation = url.path
        }
    }

    private func chooseVideoPlayer() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.application]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            defaultVideoPlayer = url.path
        }
    }

    private func toggleLoginItem(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if enabled {
                try? service.register()
            } else {
                try? service.unregister()
            }
        }
    }
}

// MARK: - Components

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            
            content
                .background { glassCard }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
    
    private var glassCard: some View {
        ZStack {
            VisualEffectView(material: .selection, blendingMode: .withinWindow)
                .opacity(0.15)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.4), .clear, .white.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                }
        }
    }
}

struct SettingsControlRow<Control: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let control: () -> Control
    
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(themeColor.color ?? Color.accentColor)
                .font(.system(size: 14))
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(T(title))
                    .font(.system(size: 13, weight: .medium))
                Text(T(subtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            control()
        }
        .padding(12)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
                    .padding(4)
            }
        }
    }
}

struct SettingsToggle: View {
    let title: String
    let subtitle: String
    let icon: String
    @Binding var isOn: Bool
    
    var body: some View {
        SettingsControlRow(title: title, subtitle: subtitle, icon: icon) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

// MARK: - Specialized Components

struct ThemeColorPicker: View {
    @Binding var selection: ThemeColor
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ThemeColor.allCases) { option in
                Button { selection = option } label: {
                    ZStack {
                        if option == .default {
                            Image(systemName: "circle.slash")
                                .font(.system(size: 14))
                                .foregroundColor(selection == option ? .primary : .secondary)
                        } else {
                            Circle()
                                .fill(option.color ?? .clear)
                                .frame(width: 18, height: 18)
                                .shadow(color: (option.color ?? .clear).opacity(0.4),
                                        radius: selection == option ? 4 : 0)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background {
                        if selection == option {
                            VisualEffectView(material: .selection, blendingMode: .withinWindow)
                                .clipShape(Circle())
                        } else {
                            Circle().fill(Color.primary.opacity(0.06))
                        }
                    }
                    .overlay {
                        Circle()
                            .stroke(selection == option
                                    ? (option.color ?? .primary)
                                    : .primary.opacity(0.15),
                                    lineWidth: selection == option ? 2 : 1)
                    }
                }
                .buttonStyle(.plain)
                .scaleEffect(selection == option ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selection)
            }
        }
    }
}

struct ResolutionPicker: View {
    @Binding var selection: Int
    
    var body: some View {
        Picker("", selection: $selection) {
            Text(T("100% (Native)")).tag(100)
            Text(T("75%")).tag(75)
            Text(T("50%")).tag(50)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: 120)
    }
}

// MARK: - WindowAccessor

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.level = .floating
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

