import SwiftUI
import SwiftData

@main
struct DiaryApp: App {
    @State private var appState = AppState()

    private let modelContainer: ModelContainer = {
        let schema = Schema([
            DiaryEntry.self,
            DiaryAttachment.self,
            SyncCheckpoint.self,
            PendingChange.self,
            SyncEvent.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create SwiftData container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
        .modelContainer(modelContainer)
    }
}
