import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct SyncActivityView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \PendingChange.createdAt, order: .forward) private var pendingChanges: [PendingChange]
    @Query(sort: \SyncEvent.timestamp, order: .reverse) private var events: [SyncEvent]

    @State private var syncCoordinator = SyncCoordinator()
    @State private var isConfirmingClear = false
    @State private var conflictResolution: PendingConflictResolution?
    @State private var discardCandidate: PendingDiscardCandidate?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if !pendingChanges.isEmpty {
                Section {
                    ForEach(pendingChanges) { change in
                        PendingChangeRow(
                            change: change,
                            isSyncing: syncCoordinator.isSyncing,
                            retry: retryPendingChanges,
                            resolve: {
                                loadConflictResolution(for: change.id)
                            },
                            discard: {
                                discardCandidate = PendingDiscardCandidate(change: change)
                            }
                        )
                    }
                } header: {
                    Text("Pending")
                } footer: {
                    Text("Queued changes sync in order. Discard removes the local queued change and refreshes from the server on the next sync.")
                }
            }

            if !events.isEmpty {
                Section("History") {
                    ForEach(events) { event in
                        SyncActivityRow(event: event)
                    }
                }
            }
        }
        .overlay {
            if events.isEmpty && pendingChanges.isEmpty {
                ContentUnavailableView(
                    "No Sync Activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Sync, create, edit, delete, and media operations will appear here.")
                )
            }
        }
        .navigationTitle("Sync Activity")
        .sheet(item: $conflictResolution) { resolution in
            ConflictResolutionView(
                resolution: resolution,
                syncCoordinator: syncCoordinator
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !pendingChanges.isEmpty {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        retryPendingChanges()
                    }
                    .disabled(syncCoordinator.isSyncing)
                }

                Button("Clear", systemImage: "trash") {
                    isConfirmingClear = true
                }
                .disabled(events.isEmpty)
            }
        }
        .alert("Sync Activity Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "The sync activity action could not be completed.")
        }
        .confirmationDialog(
            "Discard Queued Change?",
            isPresented: discardConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Discard Change", role: .destructive) {
                discardSelectedChange()
            }
            Button("Cancel", role: .cancel) {
                discardCandidate = nil
            }
        } message: {
            Text(discardCandidate?.message ?? "This removes the local queued change.")
        }
        .confirmationDialog(
            "Clear Sync Activity?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Activity", role: .destructive) {
                clearEvents()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This only clears local activity history on this device.")
        }
    }

    private func clearEvents() {
        for event in events {
            modelContext.delete(event)
        }
        try? modelContext.save()
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            errorMessage != nil
        } set: { isPresented in
            if !isPresented {
                errorMessage = nil
            }
        }
    }

    private var discardConfirmationBinding: Binding<Bool> {
        Binding {
            discardCandidate != nil
        } set: { isPresented in
            if !isPresented {
                discardCandidate = nil
            }
        }
    }

    private func retryPendingChanges() {
        Task {
            await syncCoordinator.sync(modelContext: modelContext, appState: appState)
        }
    }

    private func loadConflictResolution(for changeID: String) {
        do {
            guard let resolution = try syncCoordinator.conflictResolution(
                for: changeID,
                modelContext: modelContext
            ) else {
                errorMessage = "The conflict details are no longer available. Sync again to refresh this queue item."
                return
            }

            conflictResolution = resolution
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func discardSelectedChange() {
        guard let candidate = discardCandidate else { return }
        discardCandidate = nil

        do {
            try syncCoordinator.discardPendingChange(
                id: candidate.id,
                modelContext: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PendingChangeRow: View {
    let change: PendingChange
    let isSyncing: Bool
    let retry: () -> Void
    let resolve: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: change.symbolName)
                .font(.title3)
                .foregroundStyle(change.isFailed ? .red : .orange)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(change.displayKind) pending")
                            .font(.headline)
                            .lineLimit(2)

                        Spacer(minLength: 8)

                        Text(change.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !change.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(change.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(metadataText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let error = change.displayError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if change.isFailed {
                        Text(change.recoveryHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)

                HStack(spacing: 8) {
                    if change.canResolveConflict {
                        Button("Resolve", systemImage: "arrow.triangle.merge") {
                            resolve()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Button("Retry", systemImage: "arrow.clockwise") {
                        retry()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSyncing)

                    Button("Discard", systemImage: "trash") {
                        discard()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var metadataText: String {
        let attempts = change.attemptCount == 1 ? "1 attempt" : "\(change.attemptCount) attempts"
        if let attemptedAt = change.lastAttemptedAt {
            return "\(attempts), last tried \(attemptedAt.formatted(date: .omitted, time: .shortened))"
        }

        return "\(attempts), not tried yet"
    }
}

private struct PendingDiscardCandidate {
    let id: String
    let message: String

    init(change: PendingChange) {
        id = change.id
        message = change.recoveryHint
    }
}

private struct ConflictResolutionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    let resolution: PendingConflictResolution
    let syncCoordinator: SyncCoordinator

    @State private var isConfirmingKeepServer = false
    @State private var isConfirmingOverwrite = false
    @State private var isOverwriting = false
    @State private var copiedLocalText = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("The server changed before your queued edit synced. Pick which copy should win.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ConflictVersionSection(
                    title: "Server Version",
                    systemImage: "checkmark.icloud",
                    entryTitle: resolution.serverTitle,
                    bodyMarkdown: resolution.serverBodyMarkdown,
                    dateLabel: "Updated",
                    date: resolution.serverUpdatedAt
                )

                ConflictVersionSection(
                    title: "Your Queued Edit",
                    systemImage: "square.and.pencil",
                    entryTitle: resolution.localTitle,
                    bodyMarkdown: resolution.localBodyMarkdown,
                    dateLabel: "Entry Date",
                    date: resolution.localCreatedAt
                )

                Section {
                    Button("Keep Server Version", systemImage: "checkmark.circle") {
                        isConfirmingKeepServer = true
                    }

                    Button("Overwrite Server With My Edit", systemImage: "arrow.up.doc") {
                        isConfirmingOverwrite = true
                    }
                    .disabled(isOverwriting)

                    Button(copiedLocalText ? "Copied Local Text" : "Copy Local Text", systemImage: copiedLocalText ? "checkmark" : "doc.on.doc") {
                        copyLocalText()
                    }
                } footer: {
                    Text("Keeping server discards only the queued local edit. Overwrite retries the queued edit against the current server revision.")
                }
            }
            .navigationTitle("Resolve Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .alert("Conflict Resolution Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "The conflict could not be resolved.")
            }
            .confirmationDialog(
                "Keep Server Version?",
                isPresented: $isConfirmingKeepServer,
                titleVisibility: .visible
            ) {
                Button("Keep Server", role: .destructive) {
                    keepServerVersion()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This discards the queued local edit. The server Markdown remains unchanged.")
            }
            .confirmationDialog(
                "Overwrite Server?",
                isPresented: $isConfirmingOverwrite,
                titleVisibility: .visible
            ) {
                Button("Overwrite Server", role: .destructive) {
                    overwriteServer()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This retries your queued edit using the current server revision.")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            errorMessage != nil
        } set: { isPresented in
            if !isPresented {
                errorMessage = nil
            }
        }
    }

    private func keepServerVersion() {
        do {
            try syncCoordinator.discardPendingChange(
                id: resolution.id,
                modelContext: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func overwriteServer() {
        isOverwriting = true
        Task {
            defer { isOverwriting = false }
            do {
                try await syncCoordinator.overwriteServerForConflict(
                    id: resolution.id,
                    modelContext: modelContext,
                    appState: appState
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copyLocalText() {
        #if os(iOS)
        UIPasteboard.general.string = resolution.localClipboardText
        copiedLocalText = true
        #else
        copiedLocalText = false
        #endif
    }
}

private struct ConflictVersionSection: View {
    let title: String
    let systemImage: String
    let entryTitle: String
    let bodyMarkdown: String
    let dateLabel: String
    let date: Date

    var body: some View {
        Section {
            LabeledContent(dateLabel, value: date.formatted(date: .abbreviated, time: .shortened))

            if !entryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LabeledContent("Title", value: entryTitle)
            }

            Text(bodyMarkdown.isEmpty ? "No body text" : bodyMarkdown)
                .font(.body)
                .foregroundStyle(bodyMarkdown.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
        } header: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct SyncActivityRow: View {
    let event: SyncEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.symbolName)
                .font(.title3)
                .foregroundStyle(event.isFailure ? .red : .green)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.summary)
                        .font(.headline)
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Text(event.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let detail = event.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        SyncActivityView()
    }
    .environment(AppState())
    .modelContainer(PreviewData.container)
}
