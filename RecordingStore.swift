import Foundation

@MainActor
class RecordingStore: ObservableObject {
    static let shared = RecordingStore()
    
    @Published var recordings: [RecordingItem] = []
    private let recordingsKey = "savedRecordings"
    
    init() {
        loadRecordings()
    }
    
    func addRecording(_ item: RecordingItem) {
        recordings.insert(item, at: 0)
        saveRecordings()
    }
    
    func deleteRecording(_ item: RecordingItem) {
        try? FileManager.default.removeItem(at: item.url)
        recordings.removeAll { $0.id == item.id }
        saveRecordings()
    }
    
    private func saveRecordings() {
        if let data = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(data, forKey: recordingsKey)
        }
    }
    
    private func loadRecordings() {
        guard let data = UserDefaults.standard.data(forKey: recordingsKey),
              let items = try? JSONDecoder().decode([RecordingItem].self, from: data) else { return }
        // Filter out deleted files
        recordings = items.filter { FileManager.default.fileExists(atPath: $0.filePath) }
    }
}
