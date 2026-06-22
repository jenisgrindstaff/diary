import SwiftUI
import SwiftData

@main
struct DiaryApp: App {
    @State private var appState = AppState()
    @State private var appLock = AppLock()

    private let containerResult: Result<ModelContainer, Error>

    init() {
        let schema = Schema([
            DiaryEntry.self,
            DiaryAttachment.self,
            SyncCheckpoint.self,
            PendingChange.self,
            SyncEvent.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        containerResult = Result { try ModelContainer(for: schema, configurations: [configuration]) }
    }

    var body: some Scene {
        WindowGroup {
            switch containerResult {
            case .success(let container):
                RootView()
                    .environment(appState)
                    .environment(appLock)
                    .modelContainer(container)
            case .failure(let error):
                // The on-disk store could not be opened (e.g. a failed
                // migration). Show a recoverable message instead of crashing so
                // the user can still reach the data or reinstall deliberately.
                StorageUnavailableView(error: error)
            }
        }
    }
}

private struct StorageUnavailableView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label("Diary Storage Unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("The local diary database could not be opened. Your entries are safe on the server and will be restored after reinstalling the app.\n\n\(error.localizedDescription)")
        }
    }
}
