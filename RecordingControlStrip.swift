import SwiftUI
import AppKit
import CoreGraphics

// MARK: - Recording Mode

enum ControlStripStyle: String, Hashable, Codable {
    case standard
    case large
    case notch
}

enum RecordingMode: String, Hashable, Codable {
    case singleScreen       // no audio, specific display
    case sideBySide         // no audio, both screens horizontally
    case fullScreenAudio    // selected screen + audio
    case windowAudio        // window + audio
    case areaAudio          // area + audio

    var hasAudio: Bool {
        return true
    }
}

// MARK: - Display Info

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    var isMain: Bool { id == CGMainDisplayID() }
}

// MARK: - Notch dismiss bridge

/// Reference type so the manager can trigger the SwiftUI collapse animation
/// without fighting SwiftUI's value-type @State ownership.
class NotchDismissController: ObservableObject {
    @Published var shouldDismiss = false
}

// MARK: - Control Strip View

struct RecordingControlStripView: View {
    // MARK: - Environment & Dependencies
    @ObservedObject private var engine = RecordingEngine.shared
    @ObservedObject var dismissController: NotchDismissController = NotchDismissController()
    
    // MARK: - App Storage
    @AppStorage("controlStripStyle") private var controlStripStyle: ControlStripStyle = .standard
    @AppStorage("isLiquidGlass") private var isLiquidGlass: Bool = false
    
    // MARK: - State
    @State private var selectedMode: RecordingMode = {
        let raw = UserDefaults.standard.string(forKey: "lastRecordingMode") ?? ""
        return RecordingMode(rawValue: raw) ?? .fullScreenAudio
    }()
    @State private var selectedDisplayID: CGDirectDisplayID = (NSScreen.screens.first { $0.frame.origin == .zero }?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    @State private var displays: [DisplayInfo] = RecordingControlStripView.getCurrentDisplays()
    @State private var countdownDelay: Int = 3
    @State private var autoOpen: Bool = false
    @State private var playMediaOnStart: Bool = UserDefaults.standard.bool(forKey: "playMediaOnStart")
    @State private var pauseMediaOnFinish: Bool = UserDefaults.standard.bool(forKey: "pauseMediaOnFinish")
    @State private var notchAnimationVisible = false
    
    // MARK: - Properties
    @Namespace private var animationNamespace
    let onDismiss: () -> Void
    let onRecord: (RecordingMode, CGDirectDisplayID, Int, Bool, Bool, Bool) -> Void
    var onNotchDismiss: (() -> Void)? = nil
    var notchWidth: CGFloat = 210
    
    private var scale: CGFloat {
        switch controlStripStyle {
        case .large: return 1.25
        case .notch: return 0.8
        case .standard: return 1.0
        }
    }

    init(
        dismissController: NotchDismissController,
        onDismiss: @escaping () -> Void,
        onRecord: @escaping (RecordingMode, CGDirectDisplayID, Int, Bool, Bool, Bool) -> Void,
        onNotchDismiss: (() -> Void)? = nil,
        notchWidth: CGFloat = 210
    ) {
        self.dismissController = dismissController
        self.onDismiss = onDismiss
        self.onRecord = onRecord
        self.onNotchDismiss = onNotchDismiss
        self.notchWidth = notchWidth
    }
    
    // MARK: - Body
    
    var body: some View {
        controlStripContent
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: engine.state)
            .onChange(of: engine.state) { newState in
                if case .recording = newState {
                    dismiss()
                } else if case .idle = newState {
                    dismiss()
                }
            }
            .onChange(of: dismissController.shouldDismiss) { should in
                if should { playDismissAnimation() }
            }
            .onAppear { refreshDisplays() }
    }

    private var controlStripContent: some View {
        HStack(spacing: 0) {
            if controlStripStyle == .notch {
                leftContent
                
                Spacer()
                    .frame(width: notchWidth) // Dynamic gap for the hardware notch
                
                rightContent
            } else {
                leftContent
                divider
                rightContent
            }
        }
        .padding(.vertical, 8 * scale)
        .padding(.horizontal, 8 * scale)
        .background(
            VisualEffectBackground(cornerRadius: 14 * scale)
                .matchedGeometryEffect(id: "background", in: animationNamespace)
        )
        .fixedSize()
        .padding(.top, controlStripStyle == .notch ? 0 : 40)
        .padding(.bottom, controlStripStyle == .notch ? 40 : 0)
        .padding(.horizontal, 24)
        .environment(\.colorScheme, controlStripStyle == .notch ? .dark : .light)
        .ignoresSafeArea()
        .scaleEffect(
            controlStripStyle == .notch
                ? CGSize(width: notchAnimationVisible ? 1.0 : 0.35,
                         height: notchAnimationVisible ? 1.0 : 0.55)
                : CGSize(width: 1.0, height: 1.0),
            anchor: .top
        )
        .opacity(controlStripStyle == .notch ? (notchAnimationVisible ? 1.0 : 0.0) : 1.0)
        .onAppear {
            if controlStripStyle == .notch {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    notchAnimationVisible = true
                }
            }
        }
    }

    // MARK: - Helpers

    private func playDismissAnimation() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            notchAnimationVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            onDismiss()
        }
    }

    private func dismiss() {
        if controlStripStyle == .notch {
            dismissController.shouldDismiss = true
        } else {
            onDismiss()
        }
    }

    private func refreshDisplays() {
        displays = Self.getCurrentDisplays()
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            if let main = displays.first(where: { $0.isMain }) {
                selectedDisplayID = main.id
            }
        }
    }

    static func getCurrentDisplays() -> [DisplayInfo] {
        return NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            let name = screen.localizedName
            return DisplayInfo(id: id, name: name)
        }
    }

    // MARK: - Subviews
    
    private struct CloseButton: View {
        let scale: CGFloat
        let action: () -> Void
        @State private var isHovered = false
        
        var body: some View {
            Button(action: action) {
                ZStack {
                    Image(systemName: "xmark")
                        .font(.system(size: 11 * scale, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.75))
                }
                .frame(width: 26 * scale, height: 26 * scale)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .onHover { isHovered = $0 }
            .liquidGlass(cornerRadius: 13 * scale, isHovered: isHovered)
            .fastTooltip("Close (Esc)")
            .padding(.horizontal, 4 * scale)
        }
    }

    private struct ScreenSelectionGroup: View {
        let displays: [DisplayInfo]
        let scale: CGFloat
        @Binding var selectedDisplayID: CGDirectDisplayID
        @Binding var selectedMode: RecordingMode
        @State private var hoveredDisplayID: CGDirectDisplayID? = nil
        
        var body: some View {
            HStack(spacing: 2) {
                ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                    Button {
                        selectedDisplayID = display.id
                        selectedMode = .singleScreen
                        UserDefaults.standard.set(RecordingMode.singleScreen.rawValue, forKey: "lastRecordingMode")
                        if RecordingControlStripManager.shared.isSelecting {
                            RecordingControlStripManager.shared.cancelSelectionSilently()
                        }
                    } label: {
                        ModeButtonContent(
                            icon: "display",
                            badgeIcon: nil,
                            isSelected: selectedMode == .singleScreen && selectedDisplayID == display.id,
                            isHovered: hoveredDisplayID == display.id,
                            badge: displays.count > 1 ? "\(index + 1)" : nil,
                            scale: scale
                        )
                    }
                    .buttonStyle(.plain)
                    .liquidGlass(cornerRadius: 7 * scale, isSelected: selectedMode == .singleScreen && selectedDisplayID == display.id, isHovered: hoveredDisplayID == display.id)
                    .onHover { hovering in
                        hoveredDisplayID = hovering ? display.id : nil
                    }
                    .fastTooltip("\(T("Record")) \(display.name)")
                }

                if displays.count >= 2 {
                    ModeButton(
                        mode: .sideBySide,
                        icon: "rectangle.split.2x1",
                        tooltip: T("Record both screens side by side"),
                        selectedMode: $selectedMode,
                        scale: scale,
                        onRecord: { _,_,_,_,_,_ in } // sideBySide handles its own record trigger if needed, but here it just selects
                    )
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private struct AudioModeGroup: View {
        let displaysCount: Int
        let scale: CGFloat
        @Binding var selectedMode: RecordingMode
        let selectedDisplayID: CGDirectDisplayID
        let onRecord: (RecordingMode, CGDirectDisplayID, Int, Bool, Bool, Bool) -> Void
        
        var body: some View {
            HStack(spacing: 2) {
                if displaysCount <= 1 {
                    ModeButton(mode: .fullScreenAudio, icon: "rectangle.inset.filled", hasDot: true, tooltip: T("Record Screen"), selectedMode: $selectedMode, scale: scale, onRecord: onRecord, selectedDisplayID: selectedDisplayID)
                }
                ModeButton(mode: .windowAudio, icon: "macwindow.on.rectangle", hasDot: true, tooltip: T("Record Window"), selectedMode: $selectedMode, scale: scale, onRecord: onRecord, selectedDisplayID: selectedDisplayID)
                ModeButton(mode: .areaAudio, icon: "rectangle.dashed", hasDot: true, tooltip: T("Record Selection"), selectedMode: $selectedMode, scale: scale, onRecord: onRecord, selectedDisplayID: selectedDisplayID)
            }
            .padding(.horizontal, 4)
        }
    }

    private struct ModeButton: View {
        let mode: RecordingMode
        let icon: String
        var hasDot: Bool = false
        var tooltip: String = ""
        @Binding var selectedMode: RecordingMode
        let scale: CGFloat
        var onRecord: (RecordingMode, CGDirectDisplayID, Int, Bool, Bool, Bool) -> Void = { _,_,_,_,_,_ in }
        var selectedDisplayID: CGDirectDisplayID = 0
        
        @State private var isHovered = false
        
        var body: some View {
            Button {
                selectedMode = mode
                UserDefaults.standard.set(mode.rawValue, forKey: "lastRecordingMode")
                
                if RecordingControlStripManager.shared.isSelecting {
                    RecordingControlStripManager.shared.cancelSelectionSilently()
                }
                
                if mode == .windowAudio || mode == .areaAudio {
                    // Start selection immediately
                    onRecord(mode, selectedDisplayID, 3, false, UserDefaults.standard.bool(forKey: "playMediaOnStart"), UserDefaults.standard.bool(forKey: "pauseMediaOnFinish"))
                }
            } label: {
                ModeButtonContent(
                    icon: icon,
                    badgeIcon: hasDot ? "circle.fill" : nil,
                    isSelected: selectedMode == mode,
                    isHovered: isHovered,
                    scale: scale
                )
            }
            .buttonStyle(.plain)
            .liquidGlass(cornerRadius: 7 * scale, isSelected: selectedMode == mode, isHovered: isHovered)
            .onHover { isHovered = $0 }
            .fastTooltip(tooltip)
        }
    }

    private struct ModeButtonContent: View {
        let icon: String
        let badgeIcon: String?
        let isSelected: Bool
        let isHovered: Bool
        var badge: String? = nil
        let scale: CGFloat
        
        var body: some View {
            HStack(spacing: 3 * scale) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 15 * scale, weight: .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)

                    if let dot = badgeIcon {
                        Image(systemName: dot)
                            .font(.system(size: 6 * scale))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .offset(x: 4 * scale, y: 4 * scale)
                    }
                }

                if let label = badge {
                    Text(label)
                        .font(.system(size: 11 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, badge != nil ? 8 * scale : 6 * scale)
            .frame(minWidth: badge != nil ? 44 * scale : 36 * scale, minHeight: 32 * scale)
            .contentShape(Rectangle())
        }
    }

    private struct OptionsButton: View {
        let style: ControlStripStyle
        let scale: CGFloat
        @Binding var countdownDelay: Int
        @Binding var autoOpen: Bool
        @Binding var playMediaOnStart: Bool
        @Binding var pauseMediaOnFinish: Bool
        let onDismiss: () -> Void
        
        @State private var isHovered = false
        
        var body: some View {
            Menu {
                Button(T("Open App")) {
                    onDismiss()
                    AppDelegate.shared?.openMainWindow()
                }
                Divider()
                Text(T("Countdown Timer"))
                Button(countdownDelay == 0 ? T("✓  None")       : T("None"))       { countdownDelay = 0 }
                Button(countdownDelay == 3 ? T("✓  3 seconds")  : T("3 seconds"))  { countdownDelay = 3 }
                Button(countdownDelay == 5 ? T("✓  5 seconds")  : T("5 seconds"))  { countdownDelay = 5 }
                Divider()
                Text(T("Media Control (F8 - Keyboard)"))
                Button(playMediaOnStart ? T("✓  Send Play on record") : T("Send Play on record")) {
                    playMediaOnStart.toggle()
                    UserDefaults.standard.set(playMediaOnStart, forKey: "playMediaOnStart")
                }
                Button(pauseMediaOnFinish ? T("✓  Send Pause on finish") : T("Send Pause on finish")) {
                    pauseMediaOnFinish.toggle()
                    UserDefaults.standard.set(pauseMediaOnFinish, forKey: "pauseMediaOnFinish")
                }
                Divider()
                Button(autoOpen ? T("✓  Open when done") : T("Open when done")) { autoOpen.toggle() }
            } label: {
                HStack(spacing: 4 * scale) {
                    if style != .notch {
                        Text(T("Options"))
                            .font(.system(size: 13 * scale, weight: .regular, design: .rounded))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10 * scale, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 6 * scale)
                .contentShape(Rectangle())
            }
            .fastTooltip(T("Recording Options"))
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isHovered = $0 }
            .liquidGlass(cornerRadius: 7 * scale, isHovered: isHovered)
            .padding(.horizontal, 4 * scale)
        }
    }

    private struct RecordButton: View {
        let scale: CGFloat
        let action: () -> Void
        @State private var isHovered = false
        
        var body: some View {
            Button(action: action) {
                Text(T("Record"))
                    .font(.system(size: 14 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18 * scale)
                    .padding(.vertical, 8 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                            .fill(isHovered
                                   ? Color(red: 0.95, green: 0.25, blue: 0.25)
                                   : Color(red: 0.85, green: 0.15, blue: 0.15))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .onHover { isHovered = $0 }
            .liquidGlass(cornerRadius: 10 * scale, prominent: true, tint: .red, isHovered: isHovered)
            .fastTooltip(T("Start Recording"))
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovered)
            .padding(.leading, 4 * scale)
            .padding(.trailing, 2 * scale)
        }
    }

    private struct CountdownInPlaceView: View {
        let n: Int
        let scale: CGFloat
        let onCancel: () -> Void
        @State private var isHovered = false
        
        var body: some View {
            Button(action: onCancel) {
                HStack(spacing: 6 * scale) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13 * scale, weight: .bold))
                    Text("\(n)")
                        .font(.system(size: 14 * scale, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16 * scale)
                .padding(.vertical, 8 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                        .fill(isHovered 
                              ? Color(red: 0.95, green: 0.4, blue: 0.1) 
                              : Color(red: 0.85, green: 0.35, blue: 0.15))
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .liquidGlass(cornerRadius: 10 * scale, prominent: true, tint: .orange, isHovered: isHovered)
            .fastTooltip(String(format: T("Cancel (%lld)"), n))
            .padding(.leading, 4 * scale)
            .padding(.trailing, 2 * scale)
        }
    }

    // MARK: - Body Parts

    @ViewBuilder
    var leftContent: some View {
        HStack(spacing: 0) {
            if controlStripStyle != .notch {
                CloseButton(scale: scale, action: dismiss)
                divider
            }
            if displays.count > 1 {
                ScreenSelectionGroup(
                    displays: displays,
                    scale: scale,
                    selectedDisplayID: $selectedDisplayID,
                    selectedMode: $selectedMode
                )
            } else {
                AudioModeGroup(
                    displaysCount: displays.count,
                    scale: scale,
                    selectedMode: $selectedMode,
                    selectedDisplayID: selectedDisplayID,
                    onRecord: onRecord
                )
            }
        }
    }
    
    @ViewBuilder
    var rightContent: some View {
        HStack(spacing: 0) {
            if displays.count > 1 {
                AudioModeGroup(
                    displaysCount: displays.count,
                    scale: scale,
                    selectedMode: $selectedMode,
                    selectedDisplayID: selectedDisplayID,
                    onRecord: onRecord
                )
                divider
            }
            
            OptionsButton(
                style: controlStripStyle,
                scale: scale,
                countdownDelay: $countdownDelay,
                autoOpen: $autoOpen,
                playMediaOnStart: $playMediaOnStart,
                pauseMediaOnFinish: $pauseMediaOnFinish,
                onDismiss: dismiss
            )
            
            Group {
                if case .countdown(let n) = engine.state {
                    CountdownInPlaceView(n: n, scale: scale, onCancel: {
                        RecordingEngine.shared.cancelCountdown()
                        dismiss()
                    })
                } else {
                    RecordButton(scale: scale, action: {
                        onRecord(selectedMode, selectedDisplayID, countdownDelay, autoOpen, playMediaOnStart, pauseMediaOnFinish)
                    })
                }
            }
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95)), removal: .opacity.combined(with: .scale(scale: 0.95))))
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 26 * scale)
            .padding(.horizontal, 4 * scale)
    }

}

struct VisualEffectBackground: View {
    var cornerRadius: CGFloat = 14
    @AppStorage("isLiquidGlass") private var isLiquidGlass: Bool = false
    @AppStorage("controlStripStyle") private var controlStripStyle: ControlStripStyle = .standard

    var body: some View {
        Group {
            if controlStripStyle == .notch {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
                    .offset(y: -cornerRadius)
                    .padding(.bottom, -cornerRadius)
                    .clipped()
            } else if isLiquidGlass {
                ZStack {
                    if #available(macOS 14.0, *) {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(0.45)
                    } else {
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                            .opacity(0.45)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                    
                    LinearGradient(
                        colors: [.white.opacity(0.2), .clear, .black.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.5), .clear, .white.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
            } else {
                if #available(macOS 14.0, iOS 17.0, *) {
                    // Standard Style (Modern Material)
                    ZStack {
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(0.5))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                    )
                } else {
                    // Classic Fallback
                    ZStack {
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                    )
                }
            }
        }
    }
}


// MARK: - Custom Tooltip View
struct TooltipView: View {
    let text: String
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)),
                removal: .opacity
            ))
    }
}

// MARK: - Fast Tooltip

extension View {
    func fastTooltip(_ text: String?) -> some View {
        self.modifier(FastTooltipModifier(text: text))
    }
}

struct FastTooltipModifier: ViewModifier {
    let text: String?
    @AppStorage("controlStripStyle") private var controlStripStyle: ControlStripStyle = .standard
    @State private var showTooltip = false
    @State private var hoverTimer: Timer? = nil

    func body(content: Content) -> some View {
        content
            .onHover { isHovered in
                hoverTimer?.invalidate()
                if isHovered, text != nil, text?.isEmpty == false {
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            showTooltip = true
                        }
                    }
                } else {
                    withAnimation(.easeIn(duration: 0.1)) {
                        showTooltip = false
                    }
                }
            }
            .overlay(alignment: controlStripStyle == .notch ? .bottom : .top) {
                if showTooltip, let text = text, !text.isEmpty {
                    TooltipView(text: text)
                        .offset(y: controlStripStyle == .notch ? 36 : -36)
                        .fixedSize()
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Control Strip Panel Manager

class ControlStripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class RecordingControlStripManager {
    static let shared = RecordingControlStripManager()

    private var panel: NSPanel?
    private weak var stripHosting: NSHostingView<RecordingControlStripView>?
    private var dismissController: NotchDismissController?
    
    var isSelecting: Bool = false

    @MainActor
    func handleHotkey() {
        switch RecordingEngine.shared.state {
        case .recording:
            RecordingEngine.shared.toggleRecording()
        case .idle:
            panel?.isVisible == true ? hidePanel() : showPanel()
        default:
            break
        }
    }

    @MainActor
    func showPanel() {
        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil); return
        }

        let style = UserDefaults.standard.string(forKey: "controlStripStyle") ?? "standard"
        let isNotch = (style == "notch")
        
        let targetScreen: NSScreen
        if isNotch {
            targetScreen = builtInScreen()
        } else {
            let mouseLoc = NSEvent.mouseLocation
            targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLoc, $0.frame, false) } 
                         ?? NSScreen.main 
                         ?? NSScreen.screens.first!
        }
        
        var calculatedNotchWidth: CGFloat = 210
        if isNotch {
            if #available(macOS 12.0, *), let l = targetScreen.auxiliaryTopLeftArea, let r = targetScreen.auxiliaryTopRightArea {
                let width = r.minX - l.maxX
                if width > 0 && width < targetScreen.frame.width {
                    calculatedNotchWidth = width
                }
            }
        }

        let controller = NotchDismissController()
        dismissController = controller

        let stripView = RecordingControlStripView(
            dismissController: controller,
            onDismiss: { [weak self] in self?.closePanelImmediately() },
            onRecord:  { [weak self] mode, displayID, delay, autoOpen, playMedia, pauseMedia in
                self?.beginRecording(mode: mode, displayID: displayID, delay: delay, autoOpen: autoOpen, playMedia: playMedia, pauseMedia: pauseMedia)
            },
            notchWidth: calculatedNotchWidth
        )

        let hosting = NSHostingView(rootView: stripView)
        stripHosting = hosting
        // Force an initial layout pass to get accurate fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 200)
        let size = hosting.fittingSize
        let W = size.width, H = size.height

        let p = ControlStripPanel(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = NSColor.clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: Int(NSWindow.Level.screenSaver.rawValue) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hosting

        let contentSize = hosting.fittingSize
        
        if isNotch {
            let sf = targetScreen.frame
            
            // Measure rightContent exactly with a dedicated temp view
            let rightMeasureView = RecordingControlStripView(
                dismissController: NotchDismissController(),
                onDismiss: {},
                onRecord: { _,_,_,_,_,_ in },
                notchWidth: calculatedNotchWidth
            )
            let rightHosting = NSHostingView(rootView: rightMeasureView.rightContent)
            rightHosting.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            let rightContentWidth = rightHosting.fittingSize.width
            
            p.setContentSize(contentSize)
            
            // The total content width = outerPad*2 + innerPad*2 + leftW + notchW + rightW
            // So leftW = contentSize.width - notchW - rightW - outerPad*2 - innerPad*2
            let outerPad: CGFloat = 24.0
            let innerPad: CGFloat = 8.0 * 0.8
            let leftWidth = contentSize.width - calculatedNotchWidth - rightContentWidth - (outerPad * 2) - (innerPad * 2)
            
            // Pin window left edge so leftContent ends exactly at the hardware notch left edge
            // notchLeftEdge is auxiliaryTopLeftArea.maxX (in screen points, already correct scale)
            var notchLeftEdge = sf.midX - calculatedNotchWidth / 2  // fallback
            if #available(macOS 12.0, *), let l = targetScreen.auxiliaryTopLeftArea {
                notchLeftEdge = l.maxX
            }
            
            let originX = notchLeftEdge - leftWidth - innerPad - outerPad
            let originY = sf.maxY - contentSize.height + 2
            p.setFrameOrigin(NSPoint(x: originX, y: originY))
        } else {
            let f = targetScreen.visibleFrame
            p.setContentSize(contentSize)
            let x = f.origin.x + (f.size.width - contentSize.width) / 2
            let y = f.maxY - contentSize.height - 20
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Intercept ESC globally while panel is open
        HotkeyManager.shared.setEscHotkeyEnabled(true)

        // Auto-start selection when the saved mode requires a picker UI
        let savedModeRaw = UserDefaults.standard.string(forKey: "lastRecordingMode") ?? ""
        let savedMode = RecordingMode(rawValue: savedModeRaw) ?? .fullScreenAudio
        if savedMode == .windowAudio || savedMode == .areaAudio {
            let displayID = CGMainDisplayID()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.panel?.isVisible == true else { return }
                let playMedia = UserDefaults.standard.bool(forKey: "playMediaOnStart")
                let pauseMedia = UserDefaults.standard.bool(forKey: "pauseMediaOnFinish")
                self.beginRecording(mode: savedMode, displayID: displayID, delay: 3, autoOpen: false, playMedia: playMedia, pauseMedia: pauseMedia)
            }
        }
    }

    @MainActor
    func hidePanel() {
        let style = UserDefaults.standard.string(forKey: "controlStripStyle") ?? "standard"
        if style == "notch", let controller = dismissController {
            // Signal SwiftUI to play the collapse animation; onDismiss fires after 450ms
            controller.shouldDismiss = true
            return
        }
        closePanelImmediately()
    }

    @MainActor
    private func closePanelImmediately() {
        if case .countdown = RecordingEngine.shared.state {
            RecordingEngine.shared.cancelCountdown()
        }
        // Cancel any in-progress selection overlay so a single ESC closes everything
        if isSelecting {
            AreaSelectionManager.shared.cancel()
            WindowSelectionManager.shared.cancel()
            isSelecting = false
        }
        dismissController = nil
        stripHosting = nil
        panel?.orderOut(nil)
        panel = nil
        HotkeyManager.shared.setEscHotkeyEnabled(false)
    }

    @MainActor
    func cancelSelectionSilently() {
        if isSelecting {
            AreaSelectionManager.shared.cancel()
            WindowSelectionManager.shared.cancel()
            isSelecting = false
        }
    }

    private func builtInScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let did = CGDirectDisplayID(n.uint32Value)
                if CGDisplayIsBuiltin(did) != 0 {
                    return screen
                }
            }
        }
        return NSScreen.screens.first ?? NSScreen.main!
    }



    @MainActor
    private func beginRecording(mode: RecordingMode, displayID: CGDirectDisplayID, delay: Int, autoOpen: Bool, playMedia: Bool, pauseMedia: Bool) {
        if isSelecting { return }
        
        UserDefaults.standard.set(autoOpen, forKey: "autoOpenRecording")
        UserDefaults.standard.set(!mode.hasAudio, forKey: "muteSystemAudio")
        UserDefaults.standard.set(playMedia, forKey: "playMediaOnStart")
        UserDefaults.standard.set(pauseMedia, forKey: "pauseMediaOnFinish")

        if mode == .windowAudio {
            isSelecting = true
            HotkeyManager.shared.setEscHotkeyEnabled(false) // selection overlay owns ESC
            WindowSelectionManager.shared.startSelection { [weak self] windowID, displayID, userCancelled in
                // Delay the reset so HotkeyManager's ESC guard still fires with isSelecting=true
                // for the same ESC event that closed the selection, preventing the panel from also closing
                DispatchQueue.main.async { [weak self] in
                    self?.isSelecting = false
                    if self?.panel != nil { HotkeyManager.shared.setEscHotkeyEnabled(true) }
                    
                    guard let windowID = windowID, let dispID = displayID else {
                        if userCancelled {
                            self?.hidePanel()
                        }
                        return
                    }
                    
                    RecordingEngine.shared.startCountdownWith(
                        seconds: delay,
                        displayID: dispID,
                        sideBySide: false,
                        windowID: windowID,
                        cropRect: nil,
                        playMediaOnStart: playMedia,
                        pauseMediaOnFinish: pauseMedia
                    )
                }
            }
        } else if mode == .areaAudio {
            isSelecting = true
            HotkeyManager.shared.setEscHotkeyEnabled(false) // selection overlay owns ESC
            AreaSelectionManager.shared.startSelection { [weak self] rect, displayID, userCancelled in
                // Delay the reset so HotkeyManager's ESC guard still fires with isSelecting=true
                DispatchQueue.main.async { [weak self] in
                    self?.isSelecting = false
                    if self?.panel != nil { HotkeyManager.shared.setEscHotkeyEnabled(true) }
                    
                    guard let rect = rect, let dispID = displayID else {
                        if userCancelled {
                            self?.hidePanel()
                        }
                        return
                    }
                    
                    RecordingEngine.shared.startCountdownWith(
                        seconds: delay,
                        displayID: dispID,
                        sideBySide: false,
                        windowID: nil,
                        cropRect: rect,
                        playMediaOnStart: playMedia,
                        pauseMediaOnFinish: pauseMedia
                    )
                }
            }
        } else {
            RecordingEngine.shared.startCountdownWith(
                seconds: delay,
                displayID: displayID,
                sideBySide: mode == .sideBySide,
                windowID: nil,
                cropRect: nil,
                playMediaOnStart: playMedia,
                pauseMediaOnFinish: pauseMedia
            )
        }
    }
}
