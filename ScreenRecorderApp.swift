import SwiftUI
import AppKit
import ServiceManagement
import AVFoundation
import Combine
import Carbon

@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default
    @AppStorage("isLiquidGlass") private var isLiquidGlass: Bool = false

    var body: some Scene {
        // Main window — hidden on launch, shown from menu bar
        Window("Screen Recorder", id: "main") {
            ContentView()
                .tint(themeColor.color)
        }
        .defaultSize(width: 900, height: 620)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["main"])

        Settings {
            SettingsView()
        }

        Window("Settings", id: "settings") {
            SettingsView()
        }
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    // MARK: - Recording Status Menu Bar Item
    private var recordingStatusItem: NSStatusItem?
    private var recordingStateCancellable: AnyCancellable?


    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        UserDefaults.standard.register(defaults: ["showQuitWarning": true])

        HotkeyManager.shared.register()
        setupRecordingStatusItem()

        if !UserDefaults.standard.bool(forKey: "didRegisterLoginItem") {
            registerLoginItem()
            UserDefaults.standard.set(true, forKey: "didRegisterLoginItem")
        }
        
        setupDynamicAppIcon()
        
        let needsPermissions = !CGPreflightScreenCaptureAccess() || (AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined)
        
        if needsPermissions {
            showPermissionsWindow()
        } else {
            // Force menu bar ownership from the start
            NSApp.setActivationPolicy(.accessory)
            
            // If the app is launched normally (not as a background process), show the main window
            // Since we can't easily detect 'launch at login' here, we'll just always try to show 
            // the main window on a fresh launch unless the user explicitly wants it hidden.
            // But for now, showing it is better than 'didn't opened'.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showMainWindow()
            }
        }

        // Hide dock icon if all windows are closed (for when user clicks traffic light X)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Wait for the window to actually close and its isVisible state to update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let stillHasVisibleWindows = NSApp.windows.contains { window in
                    // Only count regular windows that are actually visible
                    window.isVisible && !(window is NSPanel) && (window.title == "Screen Recorder" || window.title == "Settings")
                }
                
                if !stillHasVisibleWindows {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        // Force menu bar ownership whenever a main window becomes key
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  !(window is NSPanel),
                  (window.title == "Screen Recorder" || window.title == "Settings") else { return }
            
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if case .recording = RecordingEngine.shared.state {
            let alert = NSAlert()
            alert.messageText = "Recording in Progress"
            alert.informativeText = "A recording is currently active. Quitting now will discard the current recording. Are you sure you want to quit?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }

        if !UserDefaults.standard.bool(forKey: "showQuitWarning") {
            return .terminateNow
        }

        let hotkeyLabel: String = {
            let key = UserDefaults.standard.integer(forKey: "globalHotkey")
            switch key {
            case 19: return "⌘2"
            case 22: return "⌘6"
            default: return "⌘4"
            }
        }()
        let currentHotkey = hotkeyLabel
        let alert = NSAlert()
        alert.messageText = "Quit Screen Recorder?"
        alert.informativeText = "Are you sure you want to quit? Global hotkey (\(currentHotkey)) will no longer be available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
    


    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func openMainWindow() {
        showMainWindow()
    }

    private func showMainWindow() {
        // Switch to regular to ensure Dock icon shows and window can be frontmost
        NSApp.setActivationPolicy(.regular)
        
        // Use the URL scheme to trigger SwiftUI's Window handling.
        // This is much more reliable than searching NSApp.windows manually.
        if let url = URL(string: "therealscreenrecorder://main") {
            NSWorkspace.shared.open(url)
        }
        
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func registerLoginItem() {
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
    }
    
    private var permissionsWindow: NSWindow?

    func showPermissionsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        if permissionsWindow == nil {
            let view = PermissionsView()
            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Permissions"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentViewController = hostingController
            window.center()
            window.isReleasedWhenClosed = false
            permissionsWindow = window
        }
        permissionsWindow?.makeKeyAndOrderFront(nil)
    }

    func closePermissionsWindowAndContinue() {
        permissionsWindow?.close()
        permissionsWindow = nil
        openMainWindow()
    }
    
    private func setupDynamicAppIcon() {
        updateAppIcon()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(updateAppIcon),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func updateAppIcon() {
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let imageName = isDarkMode ? "ScreenRecordBlack.png" : "ScreenRecordWhite.png"
        
        if let imagePath = Bundle.main.path(forResource: imageName, ofType: nil),
           let image = NSImage(contentsOfFile: imagePath) {
            NSApp.applicationIconImage = image.autoCroppedAndSquared()
        }
    }

    // MARK: - Recording Status Menu Bar Item Setup

    @MainActor
    private func setupRecordingStatusItem() {
        recordingStateCancellable = RecordingEngine.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .recording = state {
                    self?.showRecordingStatusItem()
                } else {
                    self?.hideRecordingStatusItem()
                }
            }
    }

    @MainActor
    private func showRecordingStatusItem() {
        guard recordingStatusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "Recording in progress — click to stop"
        item.button?.target = self
        item.button?.action = #selector(stopRecordingFromMenuBar)

        // Build a monochrome template icon: circle ring + filled stop square.
        // isTemplate=true lets the system invert it for dark/light menu bar automatically.
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // Circle ring
            let ringPath = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ringPath.lineWidth = 1.5
            ringPath.stroke()

            // Filled stop square in the centre
            let squareSize: CGFloat = 6.5
            let squareRect = NSRect(
                x: (rect.width  - squareSize) / 2,
                y: (rect.height - squareSize) / 2,
                width:  squareSize,
                height: squareSize
            )
            NSBezierPath(roundedRect: squareRect, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        icon.isTemplate = true
        item.button?.image = icon

        recordingStatusItem = item
    }

    @MainActor
    private func hideRecordingStatusItem() {
        if let item = recordingStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            recordingStatusItem = nil
        }
    }

    @MainActor @objc private func stopRecordingFromMenuBar() {
        // Hide the icon immediately so it feels instant
        hideRecordingStatusItem()
        Task { @MainActor in
            await RecordingEngine.shared.stopRecording()
        }
    }
}


// MARK: - NSImage Extension for App Icon
extension NSImage {
    func autoCroppedAndSquared() -> NSImage {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else { return self }
              
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        
        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let alpha = ptr[offset + 3]
                if alpha > 10 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        
        if minX > maxX || minY > maxY { return self }
        
        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return self }
        
        let cropWidth = CGFloat(cropRect.width)
        let cropHeight = CGFloat(cropRect.height)
        let croppedImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: cropWidth, height: cropHeight))
        
        let maxDim = max(cropWidth, cropHeight)
        let paddedDim = maxDim * 1.05
        
        let newSize = NSSize(width: paddedDim, height: paddedDim)
        let newImage = NSImage(size: newSize)
        
        newImage.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: newSize).fill()
        
        let drawRect = NSRect(
            x: (paddedDim - cropWidth) / 2,
            y: (paddedDim - cropHeight) / 2,
            width: cropWidth,
            height: cropHeight
        )
        croppedImage.draw(in: drawRect, from: NSRect(origin: .zero, size: croppedImage.size), operation: .sourceOver, fraction: 1.0)
        newImage.unlockFocus()
        
        return newImage
    }
    
    func aspectFitted(to newSize: NSSize) -> NSImage {
        let imageSize = self.size
        guard imageSize.width > 0 && imageSize.height > 0 else { return self }
        
        let widthRatio  = newSize.width  / imageSize.width
        let heightRatio = newSize.height / imageSize.height
        let ratio = min(widthRatio, heightRatio)
        
        let newWidth = imageSize.width * ratio
        let newHeight = imageSize.height * ratio
        
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        
        let x = (newSize.width - newWidth) / 2.0
        let y = (newSize.height - newHeight) / 2.0
        
        self.draw(in: NSRect(x: x, y: y, width: newWidth, height: newHeight),
                  from: NSRect(origin: .zero, size: imageSize),
                  operation: .sourceOver,
                  fraction: 1.0)
                  
        newImage.unlockFocus()
        return newImage
    }
}

// MARK: - HotkeyManager (⌘ + 4)

class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var localMonitor: Any?

    func register() {
        let keyCode = UInt32(UserDefaults.standard.integer(forKey: "globalHotkey"))
        let activeKeyCode = keyCode == 0 ? 21 : keyCode

        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind:  UInt32(kEventHotKeyPressed)
            )

            InstallEventHandler(
                GetApplicationEventTarget(),
                { (_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
                    var hotkeyID = EventHotKeyID()
                    GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotkeyID
                    )
                    if hotkeyID.id == 1 {
                        DispatchQueue.main.async {
                            RecordingControlStripManager.shared.handleHotkey()
                        }
                    } else if hotkeyID.id == 2 {
                        DispatchQueue.main.async {
                            RecordingControlStripManager.shared.hidePanel()
                        }
                    }
                    return noErr
                },
                1,
                &eventType,
                nil,
                &eventHandlerRef
            )
        }

        if let currentRef = hotKeyRef {
            UnregisterEventHotKey(currentRef)
            hotKeyRef = nil
        }

        let hotkeyID = EventHotKeyID(signature: OSType(0x53435234), id: 1)
        RegisterEventHotKey(
            activeKeyCode,
            UInt32(cmdKey),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        print("[HotkeyManager] Carbon RegisterEventHotKey registered (keyCode: \(activeKeyCode))")

        if let currentMonitor = localMonitor {
            NSEvent.removeMonitor(currentMonitor)
            localMonitor = nil
        }
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.keyCode == UInt16(activeKeyCode) {
                DispatchQueue.main.async {
                    RecordingControlStripManager.shared.handleHotkey()
                }
                return nil
            }
            if event.keyCode == 53 {
                if RecordingControlStripManager.shared.isSelecting {
                    return event
                }
                DispatchQueue.main.async {
                    if case .countdown = RecordingEngine.shared.state {
                        RecordingEngine.shared.cancelCountdown()
                    } else {
                        RecordingControlStripManager.shared.hidePanel()
                    }
                }
                return nil
            }
            return event
        }
    }

    func setEscHotkeyEnabled(_ enabled: Bool) {
        // Disabled global ESC hotkey to prevent interfering with other apps.
        // We now rely purely on the local monitor for ESC.
    }
}

// End of file
