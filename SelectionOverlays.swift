import AppKit
import ScreenCaptureKit
import CoreGraphics

// MARK: - Area Selection Overlay

class AreaSelectionManager {
    static let shared = AreaSelectionManager()
    private var windows: [NSWindow] = []
    
    func startSelection(completion: @escaping (CGRect?, CGDirectDisplayID?, Bool) -> Void) {
        // Clear old
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        
        let screens = NSScreen.screens
        for screen in screens {
            let window = AreaSelectionWindow(
                contentRect: NSRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.3)
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hasShadow = false
            
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            
            let view = AreaSelectionView(frame: window.contentView!.bounds, displayID: displayID)
            view.onCancel = { [weak self] in
                guard let self = self else { return }
                self.cleanup()
                completion(nil, nil, true)
            }
            window.contentView = view
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        
        setupEventMonitor(completion: completion)
        
        NSCursor.crosshair.push()
    }
    
    /// Cancel any in-progress selection from outside (e.g. hidePanel).
    func cancel() {
        guard !windows.isEmpty else { return }
        cleanup()
    }
    
    private var eventMonitor: Any?
    
    private func setupEventMonitor(completion: @escaping (CGRect?, CGDirectDisplayID?, Bool) -> Void) {
        if let existing = eventMonitor {
            NSEvent.removeMonitor(existing)
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { // ESC
                self.cleanup()
                completion(nil, nil, true)
                return nil
            } else if event.keyCode == 36 || event.keyCode == 76 { // Return or Enter
                for window in self.windows {
                    if let view = window.contentView as? AreaSelectionView, view.hasValidSelection {
                        let rect = view.getSelectionRect()
                        self.cleanup()
                        completion(rect, view.displayID, false)
                        return nil
                    }
                }
                return nil
            }
            return event
        }
    }
    
    private func cleanup() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.pop()
    }
}

class AreaSelectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class AreaSelectionView: NSView {
    private var startPoint: NSPoint?
    var currentRect: NSRect = .zero
    var displayID: CGDirectDisplayID
    var onCancel: (() -> Void)?
    
    init(frame: NSRect, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    var hasValidSelection: Bool {
        return currentRect.width > 10 && currentRect.height > 10
    }
    
    func getSelectionRect() -> CGRect {
        return CGRect(x: currentRect.origin.x,
                      y: bounds.height - currentRect.origin.y - currentRect.height,
                      width: currentRect.width,
                      height: currentRect.height)
    }
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentRect = NSRect(x: point.x, y: point.y, width: 0, height: 0)
        needsDisplay = true
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let minX = min(startPoint.x, point.x)
        let minY = min(startPoint.y, point.y)
        let maxX = max(startPoint.x, point.x)
        let maxY = max(startPoint.y, point.y)
        currentRect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        // Selection remains active, user must press Return to confirm.
        // We do not pop the cursor or complete here.
        if !hasValidSelection {
            currentRect = .zero
            needsDisplay = true
        }
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        bounds.fill()
        
        if currentRect != .zero {
            // Draw transparent hole
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            let path = NSBezierPath(rect: currentRect)
            path.fill()
            
            // Draw border
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemBlue.setStroke()
            path.lineWidth = 2.0
            
            let dash: [CGFloat] = [6.0, 4.0]
            path.setLineDash(dash, count: 2, phase: 0.0)
            path.stroke()
            
            // Draw semi-transparent overlay everywhere else
            NSColor(calibratedWhite: 0, alpha: 0.3).setFill()
            let maskPath = NSBezierPath(rect: bounds)
            maskPath.append(path.reversed)
            maskPath.fill()
        } else {
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor(calibratedWhite: 0, alpha: 0.3).setFill()
            bounds.fill()
        }
    }
}

// MARK: - Window Selection Overlay

class WindowSelectionManager {
    static let shared = WindowSelectionManager()
    private var windows: [NSWindow] = []
    private var scWindows: [SCWindow] = []
    
    func startSelection(completion: @escaping (CGWindowID?, CGDirectDisplayID?, Bool) -> Void) {
        // Clear old
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                DispatchQueue.main.async {
                    // Filter standard windows
                    self.scWindows = content.windows.filter { $0.windowLayer == 0 && $0.owningApplication != nil && $0.title != nil && $0.title?.isEmpty == false }
                    self.showOverlays(completion: completion)
                }
            } catch {
                DispatchQueue.main.async { completion(nil, nil, false) }
            }
        }
    }
    
    /// Cancel any in-progress selection from outside (e.g. hidePanel).
    func cancel() {
        guard !windows.isEmpty else { return }
        cleanup()
    }
    
    private func showOverlays(completion: @escaping (CGWindowID?, CGDirectDisplayID?, Bool) -> Void) {
        let screens = NSScreen.screens
        for screen in screens {
            let window = AreaSelectionWindow(
                contentRect: NSRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.1) // lighter for window
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            
            let view = WindowSelectionView(frame: window.contentView!.bounds, screenFrame: screen.frame, scWindows: scWindows, displayID: displayID)
            view.onComplete = { [weak self] winID in
                guard let self = self else { return }
                self.cleanup()
                completion(winID, displayID, false)
            }
            view.onCancel = { [weak self] in
                guard let self = self else { return }
                self.cleanup()
                completion(nil, nil, true)
            }
            window.contentView = view
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        
        setupEventMonitor(completion: completion)
        
        NSCursor.pointingHand.push()
    }
    
    private var eventMonitor: Any?
    
    private func setupEventMonitor(completion: @escaping (CGWindowID?, CGDirectDisplayID?, Bool) -> Void) {
        if let existing = eventMonitor {
            NSEvent.removeMonitor(existing)
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { // ESC
                self.cleanup()
                completion(nil, nil, true)
                return nil
            } else if event.keyCode == 36 || event.keyCode == 76 { // Return or Enter
                for window in self.windows {
                    if let view = window.contentView as? WindowSelectionView, let winID = view.hoveredWindow?.windowID {
                        self.cleanup()
                        completion(winID, view.displayID, false)
                        return nil
                    }
                }
                return nil
            }
            return event
        }
    }
    
    private func cleanup() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.pop()
    }
}

class WindowSelectionView: NSView {
    private var scWindows: [SCWindow]
    var hoveredWindow: SCWindow?
    private var screenFrame: NSRect
    
    var displayID: CGDirectDisplayID
    
    var onComplete: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?
    
    init(frame: NSRect, screenFrame: NSRect, scWindows: [SCWindow], displayID: CGDirectDisplayID) {
        self.screenFrame = screenFrame
        self.scWindows = scWindows
        self.displayID = displayID
        super.init(frame: frame)
        
        let trackingArea = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    override func mouseMoved(with event: NSEvent) {
        let mouseLocationNS = NSEvent.mouseLocation
        let mouseLocationCG = CGPoint(x: mouseLocationNS.x, y: NSMaxY(NSScreen.screens[0].frame) - mouseLocationNS.y)
        
        let newHovered = scWindows.first(where: { $0.frame.contains(mouseLocationCG) })
        if newHovered?.windowID != hoveredWindow?.windowID {
            hoveredWindow = newHovered
            needsDisplay = true
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        if hoveredWindow != nil {
            hoveredWindow = nil
            needsDisplay = true
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        if let hw = hoveredWindow {
            onComplete?(hw.windowID)
        } else {
            // Cancel if clicked outside a window
            onCancel?()
        }
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0, alpha: 0.1).setFill()
        bounds.fill()
        
        if let hw = hoveredWindow {
            let hwGlobalNS = NSRect(
                x: hw.frame.origin.x,
                y: NSMaxY(NSScreen.screens[0].frame) - hw.frame.origin.y - hw.frame.size.height,
                width: hw.frame.size.width,
                height: hw.frame.size.height
            )
            
            let hwLocal = NSRect(
                x: hwGlobalNS.origin.x - screenFrame.origin.x,
                y: hwGlobalNS.origin.y - screenFrame.origin.y,
                width: hwGlobalNS.width,
                height: hwGlobalNS.height
            )
            
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            let path = NSBezierPath(roundedRect: hwLocal, xRadius: 8, yRadius: 8)
            path.fill()
            
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemBlue.setStroke()
            path.lineWidth = 4.0
            path.stroke()
            
            NSColor(calibratedWhite: 0, alpha: 0.2).setFill()
            let maskPath = NSBezierPath(rect: bounds)
            maskPath.append(path.reversed)
            maskPath.fill()
        }
    }
}
