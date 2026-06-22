import SwiftUI

struct EntryRow: View {
    let entry: DiaryEntry
    var pendingChange: PendingChange?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(entry.displayTitle)
                            .font(.headline)
                            .lineLimit(1)

                        PendingChangeBadge(change: pendingChange)
                    }

                    Text(entry.createdAt, format: .dateTime.weekday(.wide).month(.abbreviated).day().year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if !entry.attachments.isEmpty {
                    Label("\(entry.attachments.count)", systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }

            Text(entry.displayExcerpt)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            EntryMetadataStrip(entry: entry)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct EntryMetadataStrip: View {
    let entry: DiaryEntry

    var body: some View {
        HStack(spacing: 8) {
            if !entry.people.isEmpty {
                ForEach(entry.people.prefix(2), id: \.self) { person in
                    Text(person)
                }
            }

            if !entry.tags.isEmpty {
                ForEach(entry.tags.prefix(3), id: \.self) { tag in
                    Text("#\(tag)")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}
