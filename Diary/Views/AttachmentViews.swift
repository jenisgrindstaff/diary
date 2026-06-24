import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import UIKit

struct AttachmentGridView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let attachments: [DiaryAttachment]
    var onSelect: (DiaryAttachment) -> Void = { _ in }

    private let mediaStore = LocalMediaStore()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Media")
                    .font(.title3.weight(.semibold))

                Text("\(attachments.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if horizontalSizeClass == .regular {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    attachmentTiles
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Attachments")
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(attachments) { attachment in
                            AttachmentTile(attachment: attachment, mediaStore: mediaStore) {
                                onSelect(attachment)
                            }
                            .containerRelativeFrame(.horizontal) { length, _ in
                                min(length * 0.84, 340)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Attachments")
            }
        }
    }

    private var attachmentTiles: some View {
        ForEach(attachments) { attachment in
            AttachmentTile(attachment: attachment, mediaStore: mediaStore) {
                onSelect(attachment)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AttachmentTile: View {
    let attachment: DiaryAttachment
    let mediaStore: LocalMediaStore
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            attachmentPreview
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(minHeight: 180)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityLabel(attachment.filename)
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        if attachment.isImage, let url = localURL {
            LocalMediaThumbnailView(
                url: url,
                kind: .image,
                maxPixelSize: 720,
                contentMode: .fit,
                placeholderSystemImage: "photo"
            )
        } else if attachment.isVideo, let url = localURL {
            VideoAttachmentThumbnail(url: url, filename: attachment.filename)
        } else {
            AttachmentPlaceholder(attachment: attachment)
        }
    }

    private var localURL: URL? {
        guard let path = attachment.localRelativePath else {
            return nil
        }

        return try? mediaStore.fileURL(relativePath: path)
    }
}

struct AttachmentFullScreenGallery: View {
    @Environment(\.dismiss) private var dismiss

    let attachments: [DiaryAttachment]

    @State private var selectedID: String

    private let mediaStore = LocalMediaStore()

    init(attachments: [DiaryAttachment], selectedID: String) {
        self.attachments = attachments
        _selectedID = State(initialValue: selectedID)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedID) {
                ForEach(attachments) { attachment in
                    AttachmentFullScreenPage(
                        attachment: attachment,
                        mediaStore: mediaStore
                    )
                    .tag(attachment.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .background(.black)
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

private struct AttachmentFullScreenPage: View {
    let attachment: DiaryAttachment
    let mediaStore: LocalMediaStore

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if attachment.isImage, let url = localURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(.white)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure:
                        fullScreenPlaceholder
                    @unknown default:
                        fullScreenPlaceholder
                    }
                }
            } else if attachment.isVideo, let url = localURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fullScreenPlaceholder
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text(attachment.filename)
                .font(.footnote)
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(14)
                .background(.black.opacity(0.55), in: .rect(cornerRadius: 8))
                .padding()
        }
    }

    private var localURL: URL? {
        guard let path = attachment.localRelativePath else {
            return nil
        }

        return try? mediaStore.fileURL(relativePath: path)
    }

    private var fullScreenPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: attachment.isVideo ? "video" : "photo")
                .font(.largeTitle)

            Text("Media not cached on this device")
                .font(.headline)
        }
        .foregroundStyle(.white.opacity(0.75))
    }
}

private struct VideoAttachmentThumbnail: View {
    let url: URL
    let filename: String

    var body: some View {
        ZStack {
            LocalMediaThumbnailView(
                url: url,
                kind: .video,
                maxPixelSize: 720,
                contentMode: .fit,
                placeholderSystemImage: "video"
            )

            Label("Play", systemImage: "play.fill")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.65), in: Capsule())
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .accessibilityLabel(filename)
    }
}

enum MediaThumbnailKind: String, Sendable {
    case image
    case video
}

struct LocalMediaThumbnailView: View {
    let url: URL
    let kind: MediaThumbnailKind
    let maxPixelSize: CGFloat
    var contentMode: ContentMode = .fill
    var placeholderSystemImage: String? = nil

    @State private var thumbnail: UIImage?
    @State private var didFail = false

    private var resolvedPlaceholderSystemImage: String {
        if let placeholderSystemImage {
            return placeholderSystemImage
        }
        return kind == .video ? "video" : "photo"
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if didFail {
                Image(systemName: resolvedPlaceholderSystemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: cacheKey) {
            if thumbnail == nil {
                didFail = false
            }
            thumbnail = await MediaThumbnailLoader.shared.thumbnail(
                for: url,
                kind: kind,
                maxPixelSize: maxPixelSize
            )
            didFail = thumbnail == nil
        }
    }

    private var cacheKey: String {
        MediaThumbnailLoader.cacheKey(for: url, kind: kind, maxPixelSize: maxPixelSize)
    }
}

actor MediaThumbnailLoader {
    static let shared = MediaThumbnailLoader()

    private var cache: [String: UIImage] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 160

    static func cacheKey(for url: URL, kind: MediaThumbnailKind, maxPixelSize: CGFloat) -> String {
        "\(kind.rawValue)|\(Int(maxPixelSize.rounded()))|\(url.standardizedFileURL.path)"
    }

    func thumbnail(for url: URL, kind: MediaThumbnailKind, maxPixelSize: CGFloat) async -> UIImage? {
        let key = Self.cacheKey(for: url, kind: kind, maxPixelSize: maxPixelSize)
        if let cached = cache[key] {
            return cached
        }

        let image = await Task.detached(priority: .utility) {
            switch kind {
            case .image:
                return Self.downsampledImage(at: url, maxPixelSize: maxPixelSize)
            case .video:
                return await Self.videoThumbnail(at: url, maxPixelSize: maxPixelSize)
            }
        }.value

        if let image {
            insert(image, forKey: key)
        }
        return image
    }

    private func insert(_ image: UIImage, forKey key: String) {
        cache[key] = image
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)

        while cacheOrder.count > cacheLimit, let oldest = cacheOrder.first {
            cache.removeValue(forKey: oldest)
            cacheOrder.removeFirst()
        }
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

    private static func videoThumbnail(at url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)

        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, error in
                guard error == nil, let cgImage else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: UIImage(cgImage: cgImage))
            }
        }
    }
}

private struct AttachmentPlaceholder: View {
    let attachment: DiaryAttachment

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: attachment.isVideo ? "video" : "photo")
                .font(.title2)

            Text(attachment.filename)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(height: 220)
    }
}
