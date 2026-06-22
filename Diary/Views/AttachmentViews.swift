import AVKit
import SwiftUI

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
                VideoPlayer(player: AVPlayer(url: url))
                    .aspectRatio(16 / 9, contentMode: .fit)
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
