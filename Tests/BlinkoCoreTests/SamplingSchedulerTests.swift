import Testing
import Foundation
@testable import BlinkoCore

@Suite("SamplingScheduler")
struct SamplingSchedulerTests {
    private var config: SamplingSchedulerConfig {
        SamplingSchedulerConfig(
            burstSeconds: 12,
            intervalSeconds: 60,
            lateGraceSeconds: 300,
            restartAfterSeconds: 300,
            retrySeconds: 30
        )
    }

    @Test("SC-01 a normal 60 s cadence over 1 h starts 60 bursts without drift")
    func sc01Cadence() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: false)

        var startTimes: [TimeInterval] = []
        var endCount = 0
        for tick in stride(from: 0.0, through: 3600.0, by: 1.0) {
            switch scheduler.action(at: tick) {
            case .startBurst:
                startTimes.append(tick)
            case .endBurst:
                endCount += 1
            case .none:
                break
            }
        }

        #expect(startTimes.count == 60)
        #expect(startTimes.first == 60)
        #expect(startTimes.last == 3600)
        #expect(startTimes.allSatisfy { $0.truncatingRemainder(dividingBy: 60) == 0 })
        #expect(endCount == 59)
        #expect(scheduler.burstEndsAt == 3612)
    }

    @Test("SC-02 a 4 h sleep produces no catch-up flood; the next burst is one interval away")
    func sc02NoCatchUpAfterSleep() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: false)

        #expect(scheduler.action(at: 60) == .startBurst)
        #expect(scheduler.action(at: 72) == .endBurst)
        scheduler.suspend(at: 100)

        let wake: TimeInterval = 100 + 4 * 3600
        #expect(scheduler.handleWake(at: wake, asleepFor: 4 * 3600) == .restarted)
        #expect(scheduler.action(at: wake) == .none)
        #expect(scheduler.action(at: wake + 59) == .none)
        #expect(scheduler.action(at: wake + 60) == .startBurst)
        #expect(scheduler.startedBursts == 2)
        #expect(scheduler.skippedOverdue == 0)
    }

    @Test("SC-02b an overdue tick without a wake notification is dropped once")
    func sc02bDroppedOverdueTick() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: false)

        let late: TimeInterval = 4 * 3600
        #expect(scheduler.action(at: late) == .none)
        #expect(scheduler.skippedOverdue == 1)
        #expect(scheduler.startedBursts == 0)
        #expect(scheduler.action(at: late + 59) == .none)
        #expect(scheduler.action(at: late + 60) == .startBurst)
        #expect(scheduler.startedBursts == 1)
    }

    @Test("SC-03 a tick 2 min late still runs the burst (grace window)")
    func sc03LateTickGrace() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: false)

        #expect(scheduler.action(at: 180) == .startBurst)
        #expect(scheduler.skippedOverdue == 0)
        #expect(scheduler.burstEndsAt == 192)
        #expect(scheduler.action(at: 192) == .endBurst)
        #expect(scheduler.nextBurstAt == 240)
    }

    @Test("SC-04 a long wake restarts the cadence and reports a reset")
    func sc04RestartAfterLongSleep() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: false)

        #expect(scheduler.handleWake(at: 1_000, asleepFor: 120) == .resumed)
        #expect(scheduler.nextBurstAt == 1_060)

        #expect(scheduler.handleWake(at: 5_000, asleepFor: 600) == .restarted)
        #expect(scheduler.nextBurstAt == 5_060)
        #expect(scheduler.isBursting == false)
    }

    @Test("SC-05 a wall clock jump backwards cannot delay the next burst")
    func sc05WallClockBackwards() {
        let clock = FakeClock(monotonicNow: 1_000)
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: clock.monotonicNow, immediateBurst: false)

        clock.advanceMonotonic(by: 60)
        #expect(scheduler.action(at: clock.monotonicNow) == .startBurst)

        clock.setWallClock(clock.now.addingTimeInterval(-2 * 3600))
        #expect(scheduler.action(at: clock.monotonicNow) == .none)

        clock.advanceMonotonic(by: 12)
        #expect(scheduler.action(at: clock.monotonicNow) == .endBurst)
        clock.advanceMonotonic(by: 48)
        #expect(scheduler.action(at: clock.monotonicNow) == .startBurst)
    }

    @Test("SC-06 a wall clock jump forward 1 day causes no flood of bursts")
    func sc06WallClockForwards() {
        let clock = FakeClock(monotonicNow: 1_000)
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: clock.monotonicNow, immediateBurst: false)

        clock.advanceMonotonic(by: 60)
        #expect(scheduler.action(at: clock.monotonicNow) == .startBurst)
        clock.setWallClock(clock.now.addingTimeInterval(24 * 3600))

        var starts = 0
        for _ in 0..<60 {
            clock.advanceMonotonic(by: 60)
            _ = scheduler.action(at: clock.monotonicNow) // ends the previous burst
            if case .startBurst = scheduler.action(at: clock.monotonicNow) {
                starts += 1
            }
        }
        #expect(starts == 60)
        #expect(scheduler.skippedOverdue == 0)
    }

    @Test("SC-07 lock and unlock pause bursts, then resume with a full interval")
    func sc07LockUnlock() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: true)

        #expect(scheduler.action(at: 0) == .startBurst)
        #expect(scheduler.isBursting)

        scheduler.suspend(at: 1)
        #expect(scheduler.isBursting == false)
        #expect(scheduler.nextDeadline(after: 1) == nil)
        #expect(scheduler.action(at: 100) == .none)
        #expect(scheduler.isIdle)

        scheduler.resume(at: 100)
        #expect(scheduler.nextBurstAt == 160)
        #expect(scheduler.action(at: 100) == .none)
        #expect(scheduler.action(at: 160) == .startBurst)
    }

    @Test("a denied due tick retries shortly instead of starting a burst")
    func deniedTickRetries() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: false)

        #expect(scheduler.action(at: 60, allowed: false) == .none)
        #expect(scheduler.deniedTicks == 1)
        #expect(scheduler.nextBurstAt == 90)
        #expect(scheduler.action(at: 89) == .none)
        #expect(scheduler.action(at: 90) == .startBurst)
    }

    @Test("changing the interval re-arms the next burst immediately")
    func intervalChangeRearms() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: false)

        // The interval can never be shorter than the burst itself (12 s).
        scheduler.setInterval(20, at: 5)
        #expect(scheduler.nextBurstAt == 25)
        #expect(scheduler.action(at: 24) == .none)
        #expect(scheduler.action(at: 25) == .startBurst)
    }

    @Test("aborting a burst keeps retrying so a quiet-hours window can end")
    func abortBurstKeepsRetrying() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: true)

        #expect(scheduler.action(at: 0) == .startBurst)
        scheduler.abortBurst(at: 1)
        #expect(scheduler.isBursting == false)
        #expect(scheduler.nextBurstAt == 61)
        #expect(scheduler.nextDeadline(after: 1) == 61)
        #expect(scheduler.action(at: 60) == .none)
        #expect(scheduler.action(at: 61) == .startBurst)
    }

    @Test("changing the burst length re-arms the end of an active burst")
    func burstLengthChangeRearmsEnd() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: true)

        #expect(scheduler.action(at: 0) == .startBurst)
        scheduler.setBurstSeconds(8, at: 2)
        #expect(scheduler.burstEndsAt == 8)
        #expect(scheduler.action(at: 7) == .none)
        #expect(scheduler.action(at: 8) == .endBurst)
        #expect(scheduler.nextBurstAt == 60)
    }

    @Test("Sample Now forces the next burst without a suspension")
    func forceBurst() {
        let scheduler = SamplingScheduler(config: config)
        scheduler.start(at: 0, immediateBurst: false)

        scheduler.forceBurst(at: 30)
        #expect(scheduler.action(at: 30) == .startBurst)

        scheduler.suspend(at: 31)
        scheduler.forceBurst(at: 40)
        #expect(scheduler.action(at: 40) == .none)
    }
}
