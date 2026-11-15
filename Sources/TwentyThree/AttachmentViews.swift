import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A small preview of an attachment: a real thumbnail for pictures, videos and documents, else the file's icon.
struct AttachmentThumb: View {
    let attachment: Attachment
    var size: CGFloat = 40
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.stored)).resizable().aspectRatio(contentMode: .fit).padding(4)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            if attachment.kind == .video {
                Image(systemName: "play.fill").font(.system(size: size * 0.22)).foregroundStyle(.white)
                    .shadow(radius: 2).padding(4)
            }
        }
        .task(id: attachment.id) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let req = QLThumbnailGenerator.Request(fileAt: attachment.storedURL, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { image = rep.nsImage }
        }
        .accessibilityHidden(true)
    }
}

/// What 23 does with a kind of file, in a word or two (shown under the name before sending).
private func handling(_ a: Attachment) -> String {
    switch a.kind {
    case .image: return "Claude can look (asks first)"
    case .video: return "frames to Claude (asks first)"
    case .pdf: return "read here, scans ask for Claude"
    case .audio: return "transcribed here"
    case .text, .document: return "read here"
    case .other: return "can't be read"
    }
}

/// Attachments waiting in the message field, each removable.
struct PendingAttachments: View {
    let items: [Attachment]
    let remove: (Attachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { a in
                    HStack(spacing: 8) {
                        AttachmentThumb(attachment: a, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Text(handling(a)).font(.caption2).foregroundStyle(a.kind == .other ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).lineLimit(1)
                        }
                        .frame(maxWidth: 170, alignment: .leading)
                        Button { remove(a) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                                .frame(width: 18, height: 18).background(Circle().fill(.primary.opacity(0.07)))
                        }
                        .buttonStyle(PressScaleStyle())
                        .help("Remove \(a.name)")
                        .accessibilityLabel("Remove \(a.name)")
                    }
                    .padding(5).padding(.trailing, 3)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.primary.opacity(0.05)))
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// Attachments on a sent message. Click one to open it (23's copy, so it still works if the original moved).
struct MessageAttachments: View {
    let items: [Attachment]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { a in
                Button { NSWorkspace.shared.open(a.storedURL) } label: {
                    if a.kind == .image || a.kind == .video {
                        AttachmentThumb(attachment: a, size: items.count == 1 ? 120 : 64)
                    } else {
                        HStack(spacing: 6) {
                            AttachmentThumb(attachment: a, size: 28)
                            Text(a.name).font(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                        }
                        .padding(5).padding(.trailing, 4)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
                    }
                }
                .buttonStyle(PressScaleStyle())
                .help("Open \(a.name)")
                .accessibilityLabel("Attachment \(a.name)")
            }
        }
    }
}
