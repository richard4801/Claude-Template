import AppKit
import AVFoundation
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

// AI suite (workstream 1): the composer's Extend tool and Upscale on a finished take. Prices come from the server (Extend's
// estimate; Upscale's sizes in features.video), or from demo mode's fake. The rules live in MuseCore (Suite/ComposerExtend.swift).

extension AppStore {
    // MARK: Extend

    /// The VIDEO slot's takes: finished video takes with a stored file, newest first.
    var extendableTakes: [ExtendTakeOption] { ComposerExtend.takes(takes) }

    func setExtendSource(_ s: ExtendSource?) { suite.composer.extend.source = s }

    /// A finished take's "Extend": the composer on Extend with that take in the VIDEO slot.
    func openExtend(_ take: Take) {
        guard let s = ExtendSource.take(take) else {
            showToast("This take has no video file to extend")
            return
        }
        suite.composer = suite.composer.extending(s)
        openTool(.extend)
    }

    /// "Upload a video": its length is read here and sent as `seconds`.
    func uploadExtendVideo() {
        guard suite.extendUpload == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.message = "A video to extend · MP4 or MOV, up to \(Int(ExtendSource.maxUploadSeconds)) s"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > InputSlots.maxMediaBytes {
            showToast("That file is over \(InputSlots.maxMediaBytes / (1024 * 1024)) MB")
            return
        }
        let mime = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        let api = self.api
        suite.extendUpload = 0
        let progress: UploadProgress = { [weak self] p in
            Task { @MainActor in
                guard let self, self.suite.extendUpload != nil else { return }
                self.suite.extendUpload = min(max(p, 0), 0.99)
            }
        }
        Task { @MainActor [weak self] in
            let seconds = await AppStore.videoSeconds(url)
            if let no = ExtendSource.uploadProblem(seconds: seconds) {
                self?.suite.extendUpload = nil
                self?.showToast(no)
                return
            }
            do {
                let ref = try await api.uploadSuiteMedia(url, contentType: mime, progress: progress)
                self?.suite.extendUpload = nil
                guard let src = ExtendSource.upload(ref, seconds: seconds, name: url.deletingPathExtension().lastPathComponent) else {
                    self?.showToast("That upload can't be extended · try another video")
                    return
                }
                self?.setExtendSource(src)
            } catch let e as ApiError {
                self?.suite.extendUpload = nil
                self?.showToast(e.friendlyMessage)
            } catch {
                self?.suite.extendUpload = nil
                self?.showToast("The upload didn't finish · try again")
            }
        }
    }

    /// A local video's length in seconds, or nil when it can't be read.
    nonisolated static func videoSeconds(_ url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric, d.seconds > 0 else { return nil }
        return d.seconds
    }

    /// Extend's prices: the current choice and each tier. No video yet: no price.
    func estimateExtend() async {
        guard suite.enabled, suite.catalog != nil, let req = suite.composer.extendRequest().map({ self.withExtendPick($0) }) else {
            suite.estimate = nil
            suite.estimateError = nil
            suite.tierEstimates = [:]
            return
        }
        do {
            suite.estimate = try await api.suiteEstimate(req)
            suite.estimateError = nil
        } catch let e as ApiError {
            suite.estimate = nil
            suite.estimateError = e.friendlyMessage
        } catch {}
        suite.tierEstimates = await tierPrices(req)
    }

    func generateExtend() {
        guard !suite.generating else { return }
        if suite.extendUpload != nil {
            showToast("Wait for the upload to finish")
            return
        }
        guard let req = suite.composer.extendRequest().map({ self.withExtendPick($0) }) else {
            showToast(suite.composer.missing(suite.composerSlots.slots) ?? "Pick a take or upload a video to extend")
            return
        }
        if let p = suite.estimate?.problem {
            showToast(p)
            return
        }
        suite.generating = true
        perform { [self] in
            defer { suite.generating = false }
            let j = try await api.suiteCreateShot(req)
            upsert(j)
            suite.shotJobIds.append(j.id)
            balance = try await api.balance()
            showToast("Extending · \(j.engineLabel) · \(Pricing.money(j.cost)). You'll get a notification when it's done.", action: "Open queue") { [weak self] in self?.go(.queue) }
        }
    }

    // MARK: Upscale

    /// The Upscale picker's sizes for a take: price × its length, greyed "Soon" until offered.
    func upscaleChoices(_ take: Take) -> [UpscaleChoice] { UpscaleOffer.choices(videoFeatures, seconds: take.durationSec) }

    /// Upscale is offered on the server now (some size is priced).
    var upscaleLive: Bool { UpscaleOffer.isLive(videoFeatures) }
}
