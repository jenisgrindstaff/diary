import Foundation
import AVFoundation
import ImageIO
import SwiftUI
import UIKit
#if canImport(JournalingSuggestions)
import JournalingSuggestions
#endif

#if canImport(JournalingSuggestions)
/// Presents Apple's on-device Journaling Suggestions picker (photos, workouts,
/// places, …) and hands the chosen moment's text back to the composer. The
/// picker runs in a separate process and only returns what the user taps, never
/// the raw data set.
///
/// Requires the Apple-gated `com.apple.developer.journal.allowed` entitlement
/// and a physical device; the picker is empty in the Simulator.
struct JournalingMomentPicker: View {
    let onPick: (String) -> Void

    var body: some View {
        JournalingSuggestionsPicker {
            Label("Add a Moment", systemImage: "sparkles")
        } onCompletion: { suggestion in
            let title = suggestion.title
            guard !title.isEmpty else { return }
            await MainActor.run { onPick(title) }
        }
    }
}
#endif

struct DraftTokenPreview: View {
    let peopleText: String
    let tagsText: String

    private var people: [String] {
        Self.cleanList(peopleText)
    }

    private var tags: [String] {
        Self.cleanList(tagsText)
    }

    var body: some View {
        if !people.isEmpty || !tags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !people.isEmpty {
                    DraftTokenRow(title: "People", items: people, prefix: nil)
                }

                if !tags.isEmpty {
                    DraftTokenRow(title: "Tags", items: tags, prefix: "#")
                }
            }
            .padding(.vertical, 2)
        }
    }

    static func cleanList(_ value: String) -> [String] {
        var seen = Set<String>()
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { item in
                guard !item.isEmpty, !seen.contains(item) else {
                    return false
                }
                seen.insert(item)
                return true
            }
    }
}

struct DraftSuggestionStrip: View {
    @Binding var peopleText: String
    @Binding var tagsText: String
    let suggestions: DraftSuggestions

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !suggestions.people.isEmpty {
                    DraftSuggestionRow(
                        title: "People",
                        suggestions: suggestions.people,
                        selectedValues: DraftTokenPreview.cleanList(peopleText)
                    ) { suggestion in
                        apply(suggestion, to: &peopleText)
                    }
                }

                if !suggestions.tags.isEmpty {
                    DraftSuggestionRow(
                        title: "Tags",
                        suggestions: suggestions.tags,
                        selectedValues: DraftTokenPreview.cleanList(tagsText)
                    ) { suggestion in
                        apply(suggestion, to: &tagsText)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func apply(_ suggestion: DraftSuggestion, to text: inout String) {
        var values = DraftTokenPreview.cleanList(text)
        let suggestionValues = suggestion.values
        let includesAll = suggestionValues.allSatisfy { values.contains($0) }

        if includesAll {
            values.removeAll { suggestionValues.contains($0) }
        } else {
            for value in suggestionValues where !values.contains(value) {
                values.append(value)
            }
        }

        text = values.joined(separator: ", ")
    }
}

struct DraftSuggestions: Equatable {
    var people: [DraftSuggestion] = []
    var tags: [DraftSuggestion] = []

    var isEmpty: Bool {
        people.isEmpty && tags.isEmpty
    }

    init(people: [DraftSuggestion] = [], tags: [DraftSuggestion] = []) {
        self.people = people
        self.tags = tags
    }

    init(suggestions: [DiarySuggestion], limit: Int = 8) {
        people = Self.rankedIndexedSuggestions(
            suggestions.filter { $0.kind == "people" },
            limit: limit
        )
        tags = Self.rankedIndexedSuggestions(
            suggestions.filter { $0.kind == "tags" },
            limit: limit
        )
    }

    init(entries: [DiaryEntry], limit: Int = 8) {
        let activeEntries = entries.filter { !$0.isTombstoned }
        people = Self.rankedSuggestions(
            activeEntries.flatMap { entry in
                entry.people.map { SuggestionInput(value: $0, date: entry.updatedAt) }
            },
            limit: limit
        )
        tags = Self.rankedSuggestions(
            activeEntries.flatMap { entry in
                entry.tags.map { SuggestionInput(value: $0, date: entry.updatedAt) }
            },
            limit: limit
        )
    }

    private static func rankedSuggestions(_ inputs: [SuggestionInput], limit: Int) -> [DraftSuggestion] {
        var scores: [String: SuggestionScore] = [:]

        for input in inputs {
            let value = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
            if var score = scores[key] {
                score.count += 1
                if input.date > score.latestDate {
                    score.latestDate = input.date
                    score.title = value
                }
                scores[key] = score
            } else {
                scores[key] = SuggestionScore(title: value, count: 1, latestDate: input.date)
            }
        }

        return scores.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }

                if lhs.latestDate != rhs.latestDate {
                    return lhs.latestDate > rhs.latestDate
                }

                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(limit)
            .map { DraftSuggestion(title: $0.title, values: [$0.title]) }
    }

    private static func rankedIndexedSuggestions(_ suggestions: [DiarySuggestion], limit: Int) -> [DraftSuggestion] {
        suggestions
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }

                if lhs.latestDate != rhs.latestDate {
                    return lhs.latestDate > rhs.latestDate
                }

                return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
            }
            .prefix(limit)
            .map { DraftSuggestion(title: $0.value, values: [$0.value]) }
    }
}

struct DraftSuggestion: Identifiable, Equatable {
    let title: String
    let values: [String]

    var id: String {
        values.joined(separator: "|")
    }
}

private struct SuggestionInput {
    var value: String
    var date: Date
}

private struct SuggestionScore {
    var title: String
    var count: Int
    var latestDate: Date
}

private struct DraftSuggestionRow: View {
    let title: String
    let suggestions: [DraftSuggestion]
    let selectedValues: [String]
    let apply: (DraftSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            apply(suggestion)
                        } label: {
                            Label(suggestion.title, systemImage: isSelected(suggestion) ? "checkmark.circle.fill" : "circle")
                        }
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("\(isSelected(suggestion) ? "Remove" : "Add") \(suggestion.title)")
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func isSelected(_ suggestion: DraftSuggestion) -> Bool {
        suggestion.values.allSatisfy { selectedValues.contains($0) }
    }
}

private struct DraftTokenRow: View {
    let title: String
    let items: [String]
    let prefix: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        Text("\(prefix ?? "")\(item)")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct MarkdownEditorField: View {
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .frame(minHeight: minHeight)
            .textInputAutocapitalization(.sentences)
            .overlay(alignment: .topLeading) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Write the memory...")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct SelectedMediaRows: View {
    let media: [MediaUploadDraft]
    let remove: (MediaUploadDraft) -> Void

    var body: some View {
        ForEach(media) { item in
            HStack(spacing: 12) {
                Label(item.filename, systemImage: item.contentType.hasPrefix("video/") ? "video" : "photo")
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(item.byteCount.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Remove", systemImage: "xmark.circle.fill") {
                    remove(item)
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(item.filename)")
            }
        }
    }
}

struct SelectedMediaPreviewGrid: View {
    let media: [MediaUploadDraft]
    let remove: (MediaUploadDraft) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 180), spacing: 12)
    ]

    var body: some View {
        if !media.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(media) { item in
                    SelectedMediaPreviewTile(item: item, remove: remove)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Selected media")
        }
    }
}

private struct SelectedMediaPreviewTile: View {
    let item: MediaUploadDraft
    let remove: (MediaUploadDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                MediaDraftThumbnail(item: item)
                    .aspectRatio(1, contentMode: .fit)

                Button("Remove", systemImage: "xmark.circle.fill") {
                    remove(item)
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.white, .black.opacity(0.55))
                .padding(6)
                .accessibilityLabel("Remove \(item.filename)")
            }
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.caption)
                    .lineLimit(1)

                Label(item.byteCount.formatted(.byteCount(style: .file)), systemImage: item.isVideo ? "video" : "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MediaDraftThumbnail: View {
    let item: MediaUploadDraft

    @State private var thumbnail: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if didFail {
                Image(systemName: item.isVideo ? "video" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }

            if item.isVideo {
                Label("Video", systemImage: "play.fill")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(8)
            }
        }
        .task(id: item.fileURL) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        didFail = false
        thumbnail = await ThumbnailLoader.thumbnail(for: item)
        didFail = thumbnail == nil
    }
}

struct PendingChangeBadge: View {
    let change: PendingChange?

    var body: some View {
        if let change {
            Label(change.isFailed ? "Failed" : "Pending", systemImage: change.isFailed ? "exclamationmark.triangle.fill" : "clock")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(change.isFailed ? .red : .orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((change.isFailed ? Color.red : Color.orange).opacity(0.12), in: Capsule())
                .accessibilityLabel(change.isFailed ? "Sync failed" : "Pending sync")
        }
    }
}

private extension MediaUploadDraft {
    var isVideo: Bool {
        contentType.hasPrefix("video/")
    }
}

private enum ThumbnailLoader {
    static func thumbnail(for item: MediaUploadDraft) async -> UIImage? {
        await Task.detached(priority: .utility) {
            if item.contentType.hasPrefix("image/") {
                return downsampledImage(at: item.fileURL, maxPixelSize: 480)
            }

            if item.contentType.hasPrefix("video/") {
                let asset = AVURLAsset(url: item.fileURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 480)

                guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                    return nil
                }
                return UIImage(cgImage: cgImage)
            }

            return nil
        }.value
    }

    private static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: image)
    }
}
