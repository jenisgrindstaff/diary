import SwiftUI
import SwiftData

@main
struct DiaryApp: App {
    @State private var appState = AppState()
    @State private var appLock = AppLock()

    var body: some Scene {
        WindowGroup {
            switch AppModelContainer.shared {
            case .success(let container):
                RootView()
                    .environment(appState)
                    .environment(appLock)
                    .modelContainer(container)
                    .onOpenURL { url in
                        guard url.scheme == "diary" else { return }
                        // diary://today and legacy diary://new open the fast
                        // append sheet used by the widget / Lock Screen.
                        if url.host == "today" || url.host == "new" {
                            appState.pendingQuickEntry = true
                        } else if url.host == "full" {
                            appState.pendingNewEntry = true
                        }
                    }
            case .failure(let error):
                // The on-disk store could not be opened (e.g. a failed
                // migration). Show a recoverable message instead of crashing so
                // the user can still reach the data or reinstall deliberately.
                StorageUnavailableView(error: error)
            }
        }
    }
}

/// The single SwiftData container for the process, shared by the app UI and by
/// App Intents so a Shortcut and the running app read and write the same store.
enum AppModelContainer {
    static let schema = Schema([
        DiaryEntry.self,
        DiaryAttachment.self,
        DiarySuggestion.self,
        SyncCheckpoint.self,
        PendingChange.self,
        SyncEvent.self
    ])

    static let shared: Result<ModelContainer, Error> = {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return Result { try ModelContainer(for: schema, configurations: [configuration]) }
    }()
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
