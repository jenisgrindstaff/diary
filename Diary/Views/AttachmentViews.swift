import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct AttachmentGridView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let attachments: [DiaryAttachment]
    private let mediaStore = LocalMediaStore()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]
    }

    @ViewBuilder
    var body: some View {
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
                        AttachmentTile(attachment: attachment, mediaStore: mediaStore)
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

    private var attachmentTiles: some View {
        ForEach(attachments) { attachment in
            AttachmentTile(attachment: attachment, mediaStore: mediaStore)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AttachmentTile: View {
    let attachment: DiaryAttachment
    let mediaStore: LocalMediaStore

    @State private var isPlayingVideo = false

    var body: some View {
        Group {
            if attachment.isImage, let url = localURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        AttachmentLoadingView()
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        AttachmentPlaceholder(attachment: attachment)
                    @unknown default:
                        AttachmentPlaceholder(attachment: attachment)
                    }
                }
            } else if attachment.isVideo, let url = localURL {
                if isPlayingVideo {
                    VideoPlayer(player: AVPlayer(url: url))
                        .aspectRatio(16 / 9, contentMode: .fit)
                } else {
                    Button {
                        isPlayingVideo = true
                    } label: {
                        VideoAttachmentThumbnail(url: url, filename: attachment.filename)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(attachment.filename)")
                }
            } else {
                AttachmentPlaceholder(attachment: attachment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(minHeight: 180)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityLabel(attachment.filename)
    }

    private var localURL: URL? {
        guard let path = attachment.localRelativePath else {
            return nil
        }

        return try? mediaStore.fileURL(relativePath: path)
    }
}

private struct VideoAttachmentThumbnail: View {
    let url: URL
    let filename: String

    @State private var thumbnail: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else if didFail {
                AttachmentVideoPlaceholder(filename: filename)
            } else {
                ProgressView()
            }

            Label("Play", systemImage: "play.fill")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.65), in: Capsule())
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .task(id: url) {
            didFail = false
            thumbnail = await VideoThumbnailLoader.thumbnail(for: url)
            didFail = thumbnail == nil
        }
    }
}

private struct AttachmentVideoPlaceholder: View {
    let filename: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "video")
                .font(.title2)

            Text(filename)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(height: 220)
    }
}

private enum VideoThumbnailLoader {
    static func thumbnail(for url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)

            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

private struct AttachmentLoadingView: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .frame(height: 220)
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
