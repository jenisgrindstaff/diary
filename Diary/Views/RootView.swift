import SwiftUI

struct RootView: View {
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
    }
}

#Preview {
    RootView()
        .environment(AppState())
        .modelContainer(PreviewData.container)
}
