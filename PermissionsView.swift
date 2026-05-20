import SwiftUI
import AVFoundation

struct PermissionsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default
    
    @State private var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    @State private var hasMicrophonePermission = false
    @State private var hasAccessibilityPermission = AXIsProcessTrusted()
    
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 30) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            
            VStack(spacing: 8) {
                Text(T("Permissions Required"))
                    .font(.title)
                    .fontWeight(.bold)
                
                Text(T("To record your screen and audio, please grant the following permissions."))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                PermissionRow(
                    title: T("Screen Recording"),
                    description: T("Required to capture your screen."),
                    icon: "macwindow",
                    isGranted: hasScreenRecordingPermission,
                    action: requestScreenRecording
                )
                
                PermissionRow(
                    title: T("Accessibility"),
                    description: T("Required for media keys (Play/Pause) integration."),
                    icon: "figure.roll",
                    isGranted: hasAccessibilityPermission,
                    action: requestAccessibility
                )
                
                PermissionRow(
                    title: T("Microphone"),
                    description: T("Optional for capturing voice and audio."),
                    icon: "mic.fill",
                    isGranted: hasMicrophonePermission,
                    action: requestMicrophone
                )
            }
            .padding(.horizontal, 20)
            
            Button(action: {
                AppDelegate.shared?.closePermissionsWindowAndContinue()
            }) {
                Text(T("Continue"))
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background((hasScreenRecordingPermission && hasAccessibilityPermission) ? (themeColor.color ?? Color.blue) : Color.gray)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(!(hasScreenRecordingPermission && hasAccessibilityPermission))
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .padding(40)
        .frame(width: 500, height: 550)
        .onReceive(timer) { _ in
            checkPermissions()
        }
        .onAppear {
            checkPermissions()
        }
    }
    
    private func checkPermissions() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
        
        if #available(macOS 10.14, *) {
            hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        } else {
            hasMicrophonePermission = true
        }
    }
    
    private func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            
            // If they already denied it, we might need to open settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        
        if !isTrusted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    private func requestMicrophone() {
        if #available(macOS 10.14, *) {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { checkPermissions() }
                }
            case .denied, .restricted:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let icon: String
    let isGranted: Bool
    let action: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.secondary)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 24))
            } else {
                Button(action: action) {
                    Text(T("Grant"))
                        .fontWeight(.medium)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.1))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color.primary.opacity(0.05))
        .cornerRadius(12)
    }
}
