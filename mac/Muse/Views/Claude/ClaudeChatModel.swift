import Foundation
import MuseCore
import Observation

/// State of one ClaudeChatView: the thread of a camera or edit session, its transcript (stored messages + the live turn),
/// the composer and Stop. Turns run on this Mac through ClaudeCodeService; the phone's turns show up live as well.
@MainActor
@Observable
final class ClaudeChatModel {
    private(set) var thread: ClaudeThread?
    private(set) var transcript = ClaudeTranscript()
    /// A turn queued or running somewhere else (the phone's, before this Mac picks it up, or the API fallback).
    private(set) var remoteTurn: ClaudeTurn?
    var composer = ""
    private(set) var loading = false
    private(set) var loadError: String?

    @ObservationIgnored private var key: String?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private weak var service: ClaudeCodeService?

    init() {}

    /// The view went away.
    func detach() {
        feedTask?.cancel()
        reloadTask?.cancel()
        feedTask = nil
        key = nil
    }

    /// Called from the view's `.task(id:)`. A different context (or a restarted service) loads afresh.
    /// What each message sent from this Mac carries in front (Recreate: a line naming the reference and the edit session).
    @ObservationIgnored var wrapOutgoing: ((String) -> String)?

    /// `fallback`: a context to use when the server doesn't accept the first one (Recreate asks for its own "recreate"
    /// context and falls back to the edit session's "edit" thread on a server that doesn't have it yet).
    func attach(_ service: ClaudeCodeService, contextKind: String, contextId: String, fallback: (kind: String, id: String)? = nil) async {
        let k = "\(ObjectIdentifier(service))|\(service.baseURL?.absoluteString ?? "demo")|\(contextKind)|\(contextId)|\(fallback?.kind ?? "")|\(fallback?.id ?? "")"
        guard service.configured, k != key || thread == nil else { return }
        key = k
        self.service = service
        feedTask?.cancel()
        let feed = service.feed()
        feedTask = Task { [weak self] in
            for await f in feed {
                guard let self, !Task.isCancelled else { break }
                self.handle(f)
            }
        }
        thread = nil
        transcript = ClaudeTranscript()
        remoteTurn = nil
        loading = true
        defer { loading = false }
        do {
            let d: ClaudeThreadDetail
            do {
                d = try await service.openThread(contextKind: contextKind, contextId: contextId)
            } catch {
                guard let fallback else { throw error }
                d = try await service.openThread(contextKind: fallback.kind, contextId: fallback.id)
            }
            thread = d.thread
            transcript.load(d.messages)
            remoteTurn = d.activeTurn.flatMap { $0.isOpen ? $0 : nil }
            loadError = nil
        } catch {
            loadError = (error as? ApiError)?.message ?? error.localizedDescription
            key = nil
        }
    }

    func reload() async {
        guard let service, let id = thread?.id, let d = try? await service.threadDetail(id) else { return }
        thread = d.thread
        transcript.load(d.messages)
        remoteTurn = d.activeTurn.flatMap { $0.isOpen ? $0 : nil }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    private func handle(_ f: ClaudeCodeService.Feed) {
        guard let tid = thread?.id else { return }
        switch f {
        case .local(let t, _, let e) where t == tid:
            transcript.apply(e)
            if case .done = e { scheduleReload() }
        case .live(.message(let t, let m)) where t == tid:
            transcript.upsert(m)
        case .live(.event(let t, let turnId, let e)) where t == tid:
            transcript.apply(e)
            if case .done = e {
                if remoteTurn?.id == turnId || turnId == nil { remoteTurn = nil }
                scheduleReload()
            }
        case .live(.turn(let turn)) where turn.threadId == tid:
            remoteTurn = turn.isOpen ? turn : nil
        case .live(.thread(let th)) where th.id == tid:
            thread = th
        case .live(.connected):
            Task { await reload() }
        default:
            break
        }
    }

    // MARK: Actions

    var runningHere: Bool { thread.map { service?.isRunning(threadId: $0.id) ?? false } ?? false }
    var answeringPhone: Bool { thread.map { service?.isAnsweringPhone(threadId: $0.id) ?? false } ?? false }
    var busy: Bool { runningHere || transcript.streaming || remoteTurn?.isOpen == true }

    func send() {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let service, let tid = thread?.id, service.info.ready else { return }
        composer = ""
        transcript.begin(userText: text, source: "mac")
        service.send(threadId: tid, text: wrapOutgoing?(text) ?? text)
    }

    /// A suggestion chip: sent as if typed (only when nothing is running).
    func send(_ text: String) {
        guard !busy else { return }
        composer = text
        send()
    }

    func stop() {
        guard let service, let tid = thread?.id else { return }
        service.stop(threadId: tid, remoteTurnId: remoteTurn?.id)
    }
}
