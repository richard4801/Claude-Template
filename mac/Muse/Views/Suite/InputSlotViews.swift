import AppKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

// AI suite (workstream 1): the Shot's input slots on the Mac. No layout decisions: `InputSlotTile` draws one slot in
// whatever frame it is given, and the screen (the composer, when its design lands) lays the tiles out from
// `model.slots.visible(tier.slots)`. The rules live in MuseCore (Suite/SuiteInputSlots.swift).

/// The slots of one shot and their uploads. Keep one per draft; pass `apply(to:_:)` the request before estimate/generate.
@MainActor @Observable
final class InputSlotsModel {
    var slots = InputSlots()

    func clear(_ id: SlotId) { slots = slots.clear(id) }

    /// Opens the file picker for a slot's kind, then uploads the file into it.
    func pick(_ id: SlotId, api: any MuseAPI) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.types(id.kind)
        panel.message = "\(id.title) · \(id.kind.hint)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        upload(url, to: id, api: api)
    }

    static func types(_ kind: SlotKind) -> [UTType] {
        switch kind {
        case .start, .middle, .end, .image: return [.jpeg, .png, .webP, .heic, .image]
        case .video: return [.mpeg4Movie, .quickTimeMovie, .movie]
        case .audio: return [.mp3, .mpeg4Audio, .wav, .audio]
        }
    }

    /// Reads and uploads a file into a slot: images as images, video and audio as studio uploads.
    func upload(_ url: URL, to id: SlotId, api: any MuseAPI) {
        let name = url.lastPathComponent
        let token = UUID()
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? (id.kind.isImage ? "image/jpeg" : id.kind == .audio ? "audio/mpeg" : "video/mp4")
        slots = slots.put(id, SlotValue(name: name, preview: id.kind.isImage ? url.path : nil, progress: 0, token: token))
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let limit = id.kind.isImage ? InputSlots.maxImageBytes : InputSlots.maxMediaBytes
        if size > limit { return fail(token, "That file is over \(limit / (1024 * 1024)) MB") }
        let progress: UploadProgress = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                self.slots = self.slots.update(token: token) { v in
                    var n = v
                    if n.progress != nil { n.progress = min(max(p, 0), 0.99) }
                    return n
                }
            }
        }
        Task { @MainActor [weak self] in
            do {
                if id.kind.isImage {
                    guard let data = try? Data(contentsOf: url) else { self?.fail(token, "Couldn't read that file"); return }
                    let ref = try await api.uploadImage(name: name, data: data, mime: mime, progress: progress)
                    self?.done(token) { $0.image = ref }
                } else {
                    let ref = try await api.uploadSuiteMedia(url, contentType: mime, progress: progress)
                    self?.done(token) { $0.media = ref }
                }
            } catch let e as ApiError {
                self?.fail(token, e.friendlyMessage)
            } catch {
                self?.fail(token, "The upload didn't finish · try again")
            }
        }
    }

    private func done(_ token: UUID, _ set: (inout SlotValue) -> Void) {
        slots = slots.update(token: token) { v in
            var n = v
            set(&n)
            n.progress = nil
            n.error = nil
            return n
        }
    }

    private func fail(_ token: UUID, _ message: String) {
        slots = slots.update(token: token) { v in
            var n = v
            n.progress = nil
            n.error = message
            return n
        }
    }
}

/// One input slot, filling the frame it is given. Empty: the kind's symbol, title and hint (click to pick). Filled: the
/// image (or the file's name for video/audio), upload progress, or the error; a remove button in the corner.
struct InputSlotTile: View {
    @Environment(\.theme) private var t
    var id: SlotId
    var value: SlotValue?
    var compact = false
    var onPick: () -> Void
    var onClear: () -> Void

    private var image: ImageRef? {
        guard id.kind.isImage else { return nil }
        if let i = value?.image { return i }
        return value?.preview.map { ImageRef(url: $0) }
    }

    private var symbol: String {
        if value?.error != nil { return "arrow.clockwise" }
        switch id.kind {
        case .audio: return "waveform"
        case .video: return "film"
        default: return value == nil ? "square.and.arrow.up" : "checkmark"
        }
    }

    private var accessibilityText: String {
        guard let v = value else { return "\(id.title), empty · \(id.kind.hint)" }
        if let e = v.error { return "\(id.title): \(e)" }
        if let p = v.progress { return "\(id.title), uploading \(Int(p * 100)) %" }
        return "\(id.title): \(v.name)"
    }

    var body: some View {
        // The same corner as the composer's empty slot cards beside it (cardRadius was 28 px in Soft Tactile on a 104 px tile).
        let shape = RoundedRectangle(cornerRadius: t.imageRadius)
        Button(action: onPick) {
            ZStack(alignment: image != nil ? .bottomLeading : .center) {
                shape.fill(t.surface)
                if let img = image { MuseImage(ref: img) }
                VStack(alignment: image != nil ? .leading : .center, spacing: 4) {
                    if image == nil {
                        Image(systemName: symbol).font(.system(size: compact ? 15 : 18, weight: .medium))
                            .foregroundStyle(value?.error != nil ? t.rec : t.ink)
                    }
                    Text(id.title).font(t.body(compact ? 11 : 12, .bold)).lineLimit(1)
                        .foregroundStyle(image != nil ? Color.white : t.ink)
                        .padding(.horizontal, image != nil ? 6 : 0).padding(.vertical, image != nil ? 2 : 0)
                        .background(image != nil ? Color.black.opacity(0.55) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    if let e = value?.error {
                        Text(e).font(t.body(11)).foregroundStyle(image != nil ? Color.white : t.rec).lineLimit(2).multilineTextAlignment(image != nil ? .leading : .center)
                    } else if let v = value, !id.kind.isImage {
                        Text(v.name).font(t.body(11)).foregroundStyle(t.muted).lineLimit(1).truncationMode(.middle)
                    } else if value == nil, !compact {
                        Text(id.kind.hint).font(t.body(11)).foregroundStyle(t.muted).lineLimit(2).multilineTextAlignment(.center)
                    }
                }
                .padding(compact ? 6 : 10)
                if let p = value?.progress {
                    VStack {
                        Spacer()
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(t.line)
                                Rectangle().fill(t.accent).frame(width: g.size.width * max(0.04, min(1, p)))
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(value?.ready == true ? t.ink : t.line, lineWidth: value?.ready == true ? 2 : t.lineWidth))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .overlay(alignment: .topTrailing) {
            if value != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Circle().fill(Color.black.opacity(0.6)))
                        .padding(6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel("Remove \(id.title)")
            }
        }
    }
}
