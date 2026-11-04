import XCTest
@testable import MuseCore

/// Keep GPU warm: the rules (boot, per-minute billing, idle and cap auto-off, warnings, Keep warm, credit floor),
/// the words on screen, the wire format (plans/api.md) and the in-process fake.
final class WarmGpuTests: XCTestCase {
    private let min: Int64 = 60_000
    private let t0: Int64 = 1_000_000_000

    private func sim(boot: Double = 240) -> WarmGpuSim { WarmGpuSim(config: WarmGpuSim.Config(bootSeconds: boot)) }

    private func charges(_ outs: [WarmGpuSim.Output]) -> Double {
        outs.reduce(0) { if case .charge(let v) = $1 { return $0 + v } else { return $0 } }
    }

    private func warnings(_ outs: [WarmGpuSim.Output]) -> [WarmGpuWarning] {
        outs.compactMap { if case .warning(let w) = $0 { return w } else { return nil } }
    }

    func testBootsThenBillsPerMinute() throws {
        var s = sim()
        try s.turnOn(now: t0, creditUsd: 50)
        XCTAssertEqual(s.status(now: t0).state, "starting")
        XCTAssertTrue(s.status(now: t0).isOn)
        XCTAssertEqual(WarmGpuText.indicator(s.status(now: t0)), "Add-on engine starting…")
        XCTAssertEqual(charges(s.tick(now: t0 + 30_000, creditUsd: 50)), 0)
        // While starting only the cap counts.
        XCTAssertEqual(s.status(now: t0 + 30_000).autoOffReason, "cap")
        // The boot time is billed too (the pod's whole wall time).
        let outs = s.tick(now: t0 + 4 * min, creditUsd: 50)
        XCTAssertTrue(outs.contains(.ready))
        XCTAssertEqual(charges(outs), 4 * 3.99 / 60, accuracy: 1e-9)
        let ready = s.status(now: t0 + 4 * min)
        XCTAssertEqual(ready.state, "warm")
        XCTAssertEqual(ready.readyAt, t0 + 4 * min)
        XCTAssertEqual(ready.autoOffReason, "idle")
        XCTAssertEqual(ready.autoOffAt, t0 + 24 * min) // idle counts from ready
        XCTAssertEqual(ready.warningAt, t0 + 19 * min)
        // 42 minutes at $3.99/h → $2.79 so far.
        _ = s.tick(now: t0 + 42 * min, creditUsd: 50, busy: true)
        let g = s.status(now: t0 + 42 * min)
        XCTAssertEqual(g.minutes, 42)
        XCTAssertEqual(g.costUsd, 2.793, accuracy: 1e-9)
        XCTAssertTrue(g.busy)
        XCTAssertEqual(WarmGpuText.indicator(g), "Add-on engine ready · 42 min · $2.79")
    }

    func testIdleWarningThenAutoOff() throws {
        var s = sim(boot: 0)
        try s.turnOn(now: t0, creditUsd: 50)
        XCTAssertEqual(s.autoOff()?.at, t0 + 20 * min)
        XCTAssertTrue(warnings(s.tick(now: t0 + 14 * min, creditUsd: 50)).isEmpty)
        let w = warnings(s.tick(now: t0 + 15 * min, creditUsd: 50))
        XCTAssertEqual(w, [WarmGpuWarning(reason: "idle", autoOffAt: t0 + 20 * min, message: "Add-on engine turns off in 5 min (no renders)")])
        XCTAssertEqual(s.status(now: t0 + 15 * min).pendingWarning(now: t0 + 15 * min)?.reason, "idle")
        // Warned once, not every tick.
        XCTAssertTrue(warnings(s.tick(now: t0 + 16 * min, creditUsd: 50)).isEmpty)
        // A late tick still ends it at the idle deadline and bills up to there only.
        let off = s.tick(now: t0 + 21 * min, creditUsd: 50)
        XCTAssertEqual(off.last, .off(reason: "idle"))
        let g = s.status(now: t0 + 21 * min)
        XCTAssertFalse(g.isOn)
        XCTAssertNil(g.autoOffAt)
        XCTAssertEqual(g.lastOff?.reason, "idle")
        XCTAssertEqual(g.lastOff?.minutes, 20)
        XCTAssertEqual(g.lastOff?.costUsd ?? 0, 1.33, accuracy: 1e-9)
        XCTAssertEqual(WarmGpuText.offMessage(g.lastOff), "Add-on engine turned off: no renders for a while · 20 min · $1.33 in all")
        // lastOff shows for an hour.
        XCTAssertNil(s.status(now: t0 + 81 * min).lastOff)
    }

    func testRendersAndKeepWarmHoldIt() throws {
        var s = sim(boot: 0)
        try s.turnOn(now: t0, creditUsd: 50)
        _ = s.tick(now: t0 + 15 * min, creditUsd: 50)
        try s.keepWarm(now: t0 + 16 * min)
        XCTAssertEqual(s.autoOff()?.at, t0 + 36 * min)
        XCTAssertTrue(s.status(now: t0 + 16 * min).canExtend) // an idle Keep warm doesn't use up the extension
        // A running render keeps it from going idle; idle counts again from when it ends.
        for m in stride(from: Int64(17), through: 60, by: 1) { _ = s.tick(now: t0 + m * min, creditUsd: 50, busy: true) }
        XCTAssertTrue(s.isOn)
        XCTAssertEqual(s.status(now: t0 + 60 * min).autoOffReason, "cap")
        _ = s.tick(now: t0 + 61 * min, creditUsd: 50, busy: false)
        XCTAssertEqual(s.autoOff()?.at, t0 + 80 * min)
    }

    func testSessionCapExtendsOnce() throws {
        var s = sim(boot: 0)
        try s.turnOn(now: t0, creditUsd: 100)
        for m in stride(from: Int64(1), through: 114, by: 1) { _ = s.tick(now: t0 + m * min, creditUsd: 100, busy: true) }
        let w = warnings(s.tick(now: t0 + 115 * min, creditUsd: 100, busy: true))
        XCTAssertEqual(w.first?.reason, "cap")
        XCTAssertEqual(w.first?.autoOffAt, t0 + 120 * min)
        XCTAssertTrue(s.status(now: t0 + 115 * min).canExtend)
        try s.keepWarm(now: t0 + 116 * min)
        let g = s.status(now: t0 + 116 * min)
        XCTAssertFalse(g.canExtend)
        XCTAssertEqual(g.maxMinutes, 240)
        for m in stride(from: Int64(117), through: 235, by: 1) { _ = s.tick(now: t0 + m * min, creditUsd: 100, busy: true) }
        XCTAssertEqual(s.status(now: t0 + 235 * min).pendingWarning(now: t0 + 235 * min)?.reason, "cap")
        // Keep warm again doesn't extend a second time.
        try s.keepWarm(now: t0 + 236 * min)
        XCTAssertEqual(s.status(now: t0 + 236 * min).maxMinutes, 240)
        XCTAssertEqual(s.tick(now: t0 + 240 * min, creditUsd: 100, busy: true).last, .off(reason: "cap"))
    }

    func testCreditFloorAndOwnerBalance() throws {
        var s = sim(boot: 0)
        // 10 minutes at $3.99/h = $0.665.
        XCTAssertThrowsError(try s.turnOn(now: t0, creditUsd: 0.6)) { XCTAssertEqual(($0 as? ApiError)?.code, "insufficient_balance") }
        try s.turnOn(now: t0, creditUsd: 1.0)
        XCTAssertEqual(s.tick(now: t0 + 6 * min, creditUsd: 1.0).last, .off(reason: "credit"))
        var o = sim(boot: 0)
        try o.turnOn(now: t0, creditUsd: 50)
        XCTAssertEqual(o.tick(now: t0 + min, creditUsd: 50, ownerBalanceLow: true).last, .off(reason: "owner_balance"))
    }

    func testManualOffBillsThePartMinute() throws {
        var s = sim()
        try s.turnOn(now: t0, creditUsd: 50)
        try s.turnOn(now: t0 + min, creditUsd: 50)
        XCTAssertEqual(s.startedAt, t0)
        _ = s.tick(now: t0 + 2 * min, creditUsd: 50)
        let last = s.turnOff(now: t0 + 2 * min + 30_000)
        XCTAssertEqual(last, 0.5 * 3.99 / 60, accuracy: 1e-9)
        let g = s.status(now: t0 + 3 * min)
        XCTAssertEqual(g.lastOff?.reason, "user")
        XCTAssertEqual(g.lastOff?.costUsd ?? 0, 2.5 * 3.99 / 60, accuracy: 1e-4)
        XCTAssertTrue(s.tick(now: t0 + 3 * min, creditUsd: 50).isEmpty)
        XCTAssertThrowsError(try s.keepWarm(now: t0 + 3 * min)) { XCTAssertEqual(($0 as? ApiError)?.code, "not_warm") }
    }

    func testWords() {
        XCTAssertEqual(WarmGpuText.costWarning(),
                       "Keeps the add-on engine ready so Edit renders start right away. About $4/hour from the studio balance while it's on, and it turns off by itself after 20 min without renders.")
        XCTAssertEqual(WarmGpuText.switchLabel, "Keep add-on engine ready")
        XCTAssertEqual(WarmGpuText.warningTitle(WarmGpuWarning(reason: "idle", autoOffAt: 0)), "Add-on engine turns off in 5 min (no renders)")
        XCTAssertEqual(WarmGpuText.duration(42.9), "42 min")
        XCTAssertEqual(WarmGpuText.duration(65), "1 h 05 min")
        XCTAssertEqual(WarmGpuText.indicator(WarmGpu(state: "warm", minutes: 42, costUsd: 2.8)), "Add-on engine ready · 42 min · $2.80")
        XCTAssertEqual(WarmGpuText.indicator(WarmGpu(state: "starting")), "Add-on engine starting…")
        // Owner-only words, but still no GPU or provider names.
        for r in ["user", "idle", "cap", "credit", "owner_balance", "gpu_lost"] {
            let m = WarmGpuText.offMessage(WarmGpuOff(reason: r, at: 0, minutes: 3, costUsd: 0.2))
            XCTAssertFalse(m.lowercased().contains("gpu"), m)
        }
        XCTAssertFalse(WarmGpu(state: "stopping").isOn)
    }

    func testLiveBetweenTicks() {
        let g = WarmGpu(state: "warm", startedAt: t0, minutes: 40, costUsd: 2.66, autoOffAt: t0 + 60 * min)
        let l = g.live(now: t0 + 42 * min + 30_000)
        XCTAssertEqual(l.minutes, 42.5, accuracy: 1e-9)
        XCTAssertEqual(l.costUsd, 2.79, accuracy: 1e-9)
        XCTAssertEqual(WarmGpuText.indicator(l), "Add-on engine ready · 42 min · $2.79")
        XCTAssertEqual(g.minutesLeft(now: t0 + 42 * min + 30_000), 18)
        XCTAssertEqual(WarmGpu.off.live(now: t0).minutes, 0)
        XCTAssertEqual(WarmGpu(state: "warm", startedAt: t0, minutes: 5, costUsd: 9).live(now: t0 + min).costUsd, 9)
    }

    /// The shapes in plans/api.md.
    func testWireFormat() throws {
        let warn = #"""
        {"type":"gpu","event":"warning","gpu":{"state":"warm","startedAt":1700000000000,"readyAt":1700000240000,"minutes":42,"costUsd":2.793,"ratePerHour":3.99,
         "busy":false,"autoOffAt":1700002520000,"autoOffReason":"idle","warningAt":1700002220000,"idleMinutes":20,"maxMinutes":120,"canExtend":true,"allowed":true},
         "warning":{"reason":"idle","autoOffAt":1700002520000,"message":"Add-on engine turns off in 5 min (no renders)"}}
        """#
        let e = try JSONDecoder().decode(ApiEvent.self, from: Data(warn.utf8))
        XCTAssertEqual(e.type, "gpu")
        XCTAssertEqual(e.event, "warning")
        XCTAssertEqual(e.gpu?.state, "warm")
        XCTAssertEqual(e.gpu?.isOn, true)
        XCTAssertEqual(e.gpu?.costUsd, 2.793)
        XCTAssertEqual(e.gpu?.autoOffReason, "idle")
        XCTAssertEqual(e.gpu?.canExtend, true)
        XCTAssertEqual(e.warning?.reason, "idle")
        XCTAssertEqual(e.warning?.message, "Add-on engine turns off in 5 min (no renders)")

        let off = #"""
        {"state":"off","startedAt":null,"readyAt":null,"minutes":0,"costUsd":0,"ratePerHour":3.99,"busy":false,"autoOffAt":null,"idleMinutes":20,"maxMinutes":120,
         "canExtend":false,"allowed":false,"lastOff":{"reason":"credit","at":1700000600000,"minutes":10,"costUsd":0.665}}
        """#
        let g = try JSONDecoder().decode(WarmGpu.self, from: Data(off.utf8))
        XCTAssertFalse(g.isOn)
        XCTAssertFalse(g.allowed)
        XCTAssertNil(g.autoOffAt)
        XCTAssertEqual(g.lastOff?.reason, "credit")
        XCTAssertEqual(WarmGpuText.offMessage(g.lastOff), "Add-on engine turned off: the studio balance is low · 10 min · $0.67 in all")

        // Captured from a local server/api: on → stopping → off.
        let stopping = #"{"type":"gpu","event":"state","gpu":{"state":"stopping","startedAt":1793819699564,"readyAt":1793819699564,"minutes":0,"costUsd":0,"ratePerHour":3.99,"busy":false,"autoOffAt":1793826899564,"autoOffReason":"cap","warningAt":1793826599564,"idleMinutes":20,"maxMinutes":120,"canExtend":true,"allowed":true}}"#
        XCTAssertEqual(try JSONDecoder().decode(ApiEvent.self, from: Data(stopping.utf8)).gpu?.isOn, false)
        let offEvent = #"{"type":"gpu","event":"state","gpu":{"state":"off","startedAt":null,"readyAt":null,"minutes":0,"costUsd":0,"ratePerHour":3.99,"busy":false,"autoOffAt":null,"idleMinutes":20,"maxMinutes":120,"canExtend":false,"allowed":true,"lastOff":{"reason":"user","at":1793819707606,"minutes":0,"costUsd":0.0089}}}"#
        let oe = try JSONDecoder().decode(ApiEvent.self, from: Data(offEvent.utf8))
        XCTAssertEqual(oe.gpu?.lastOff?.reason, "user")
        XCTAssertEqual(WarmGpuText.offMessage(oe.gpu?.lastOff), "Add-on engine off · 0 min · $0.01 in all")

        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try enc.encode(WarmGpuRequest.turnOn), as: UTF8.self), #"{"on":true}"#)
        XCTAssertEqual(String(decoding: try enc.encode(WarmGpuRequest.turnOff), as: UTF8.self), #"{"on":false}"#)
        XCTAssertEqual(String(decoding: try enc.encode(WarmGpuRequest.keepWarm), as: UTF8.self), #"{"extend":true}"#)

        let job = try JSONDecoder().decode(Job.self, from: Data(#"{"id":"j1","state":"done","warm":true,"cost":0}"#.utf8))
        XCTAssertEqual(job.warm, true)
        // warmGpuAllowed is gone (owner only now); an older server's field is ignored.
        let st = try JSONDecoder().decode(StudioSettings.self, from: Data(#"{"warmGpuAllowed":"owner","warmIdleMinutes":30,"warmMaxMinutes":90}"#.utf8))
        XCTAssertEqual(st.warmIdleMinutes, 30)
        XCTAssertEqual(st.warmMaxMinutes, 90)
    }

    func testFakeSwitchOnKeepWarmAndOff() async throws {
        let api = FakeMuseAPI(speed: 0)
        var g = try await api.warmGpu()
        XCTAssertFalse(g.isOn)
        XCTAssertTrue(g.allowed)
        let events = api.events()
        g = try await api.setWarmGpu(.turnOn)
        XCTAssertEqual(g.state, "starting")
        XCTAssertNotNil(g.autoOffAt)
        var it = events.makeAsyncIterator()
        let e = await it.next()
        XCTAssertEqual(e?.type, "gpu")
        XCTAssertEqual(e?.event, "state")
        XCTAssertEqual(e?.gpu?.isOn, true)
        // Idempotent while on.
        let again = try await api.setWarmGpu(.turnOn)
        XCTAssertEqual(again.startedAt, g.startedAt)
        g = try await api.setWarmGpu(.keepWarm)
        XCTAssertTrue(g.isOn)
        g = try await api.setWarmGpu(.turnOff)
        XCTAssertFalse(g.isOn)
        XCTAssertEqual(g.lastOff?.reason, "user")
        await expect("not_warm") { _ = try await api.setWarmGpu(.keepWarm) }
        // Fine when already off.
        _ = try await api.setWarmGpu(.turnOff)
    }

    func testFakeStudioSettings() async throws {
        let api = FakeMuseAPI(speed: 0)
        _ = try await api.signIn(SignInRequest(email: "you@studio.com", password: ""))
        let st = try await api.updateStudioSettings(StudioSettingsPatch(warmIdleMinutes: 30))
        XCTAssertEqual(st.warmIdleMinutes, 30)
        // The demo user is the owner; the new idle rule applies to new sessions.
        let g = try await api.warmGpu()
        XCTAssertTrue(g.allowed)
        XCTAssertEqual(g.idleMinutes, 30)
        await expect("bad_request") { _ = try await api.updateStudioSettings(StudioSettingsPatch(warmIdleMinutes: 2)) }
    }

    private func expect(_ code: String, line: UInt = #line, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("expected \(code)", line: line)
        } catch let e as ApiError {
            XCTAssertEqual(e.code, code, line: line)
        } catch {
            XCTFail("unexpected \(error)", line: line)
        }
    }
}
