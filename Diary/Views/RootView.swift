import LocalAuthentication
import SwiftUI

struct RootView: View {
    @Environment(AppLock.self) private var appLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Timeline", systemImage: "book.pages") {
                TimelineView()
            }

            Tab(role: .search) {
                SearchView()
            }

            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay {
            if appLock.isLocked {
                LockScreenView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appLock.isLocked)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Lock as soon as we leave the foreground so the app switcher
                // snapshot and the next launch are gated.
                appLock.lock()
            case .active:
                if appLock.isLocked {
                    Task { await appLock.authenticate() }
                }
            default:
                break
            }
        }
    }
}

private struct LockScreenView: View {
    @Environment(AppLock.self) private var appLock

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThickMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text("Diary is Locked")
                    .font(.title2.weight(.semibold))

                if let error = appLock.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button {
                    Task { await appLock.authenticate() }
                } label: {
                    Label("Unlock", systemImage: appLock.unlockSymbolName)
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
        .environment(AppLock())
        .modelContainer(PreviewData.container)
}
