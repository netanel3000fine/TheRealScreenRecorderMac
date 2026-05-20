# Screen Recorder
A native macOS screen recorder with system audio — no BlackHole, no tricks.

## Features
- ✅ Records screen + system audio natively via ScreenCaptureKit
- ✅ No microphone, no BlackHole, no audio routing needed
- ✅ Lives in the menu bar
- ✅ Global shortcut ⌘4 to start/stop from anywhere
- ✅ Launches at login (Login Items)
- ✅ File manager built into the main window
- ✅ Matches BookmarkCleaner design (Liquid Glass, theme colors)
- ✅ Saves .mp4 to ~/Movies/Screen Recordings/

---

## Setup in Xcode

### 1. Create a new Xcode project
- Open Xcode → New Project → macOS → App
- Product Name: `Screen Recorder`
- Bundle Identifier: `com.yourname.screenrecorder`
- Interface: SwiftUI
- Language: Swift
- Minimum deployment: macOS 13.0

### 2. Add the source files
Replace the default files and add all `.swift` files from this folder:
- `ScreenRecorderApp.swift`
- `RecordingEngine.swift`
- `ContentView.swift`
- `MenuBarView.swift`
- `ThemeManager.swift`
- `SettingsView.swift`

### 3. Replace Info.plist
- Delete Xcode's default Info.plist entries
- Copy the contents of `Info.plist` from this folder

### 4. Set up Entitlements
- In project settings → Signing & Capabilities:
  - Add **App Sandbox**
  - Add **Screen Recording** capability (or paste entitlements manually)
- Replace the generated `.entitlements` file with `ScreenRecorder.entitlements`

### 5. Build & Run
- Press ⌘R
- macOS will ask for Screen Recording permission on first launch — grant it
- The app appears in your menu bar

---

## How it works

Uses **ScreenCaptureKit** (macOS 12.3+):
```swift
config.capturesAudio = true                // ✅ system audio
config.excludesCurrentProcessAudio = true  // ✅ no app sounds
```
Audio goes directly from the system audio mixer into an AVAssetWriter alongside 
the H.264 video stream — no virtual drivers, no routing.

---

## Requirements
- macOS 13.0+
- Xcode 15+
- Screen Recording permission (macOS will prompt automatically)
