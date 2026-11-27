import Testing
import Foundation
@testable import BlinkoCore

@Suite("EyeBreakTimer")
struct EyeBreakTimerTests {
    private func makeTimer(
        interval: TimeInterval = 1_200,
        rest: TimeInterval = 20,
        enabled: Bool = true
    ) -> EyeBreakTimer {
        EyeBreakTimer(
            config: EyeBreakTimerConfig(
                enabled: enabled,
                interval: interval,
                restSeconds: rest
            )
        )
    }

    @Test("EB-01 the first break is one full interval away")
    func eb01InitialDelay() {
        var timer = makeTimer()
        timer.start(at: 100)

        #expect(timer.nextBreakAt == 1_300)
        #expect(timer.evaluate(now: 1_299) == .none)
        #expect(timer.evaluate(now: 1_300) == .beginRest)
    }

    @Test("EB-02 a break rests for the configured duration, then ends")
    func eb02RestWindow() {
        var timer = makeTimer()
        timer.start(at: 0)

        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.isResting)
        #expect(timer.restEndsAt == 1_220)
        #expect(timer.nextDeadline() == 1_220)
        #expect(timer.evaluate(now: 1_219) == .none)
        #expect(timer.evaluate(now: 1_220) == .endRest)
        #expect(timer.isResting == false)
    }

    @Test("EB-03 no second break begins while one is resting")
    func eb03NoOverlap() {
        var timer = makeTimer()
        timer.start(at: 0)

        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_205) == .none)
        #expect(timer.evaluate(now: 1_219) == .none)
        #expect(timer.breakCount == 1)
    }

    @Test("EB-04 a break due during suppression is rescheduled, not fired late")
    func eb04SuppressionSkips() {
        var timer = makeTimer()
        timer.start(at: 0)

        #expect(timer.evaluate(now: 1_200, suppression: .paused) == .suppressed(.paused))
        #expect(timer.nextBreakAt == 2_400)
        #expect(timer.evaluate(now: 1_201) == .none)
        #expect(timer.evaluate(now: 2_399) == .none)
        #expect(timer.evaluate(now: 2_400) == .beginRest)
    }

    @Test("EB-05 a manual break starts now and resets the cadence")
    func eb05ManualBreak() {
        var timer = makeTimer()
        timer.start(at: 0)

        #expect(timer.beginNow(at: 100) == .beginRest)
        #expect(timer.restEndsAt == 120)
        #expect(timer.nextBreakAt == nil)
        #expect(timer.evaluate(now: 120) == .endRest)
        #expect(timer.nextBreakAt == 1_320)
    }

    @Test("EB-06 changing the interval re-arms from now")
    func eb06IntervalChange() {
        var timer = makeTimer()
        timer.start(at: 0)

        timer.setInterval(600, at: 100)
        #expect(timer.nextBreakAt == 700)
        #expect(timer.evaluate(now: 699) == .none)
        #expect(timer.evaluate(now: 700) == .beginRest)
    }

    @Test("EB-07 disabling stops future breaks; re-enabling starts a fresh interval")
    func eb07Disable() {
        var timer = makeTimer()
        timer.start(at: 0)

        timer.setEnabled(false, at: 100)
        #expect(timer.nextBreakAt == nil)
        #expect(timer.nextDeadline() == nil)
        #expect(timer.evaluate(now: 9_999) == .none)

        timer.setEnabled(true, at: 10_000)
        #expect(timer.nextBreakAt == 11_200)

        var disabled = makeTimer(enabled: false)
        disabled.start(at: 0)
        #expect(disabled.nextBreakAt == nil)
        #expect(disabled.evaluate(now: 9_999) == .none)
    }

    @Test("EB-08 ending a rest schedules the next break a full interval later")
    func eb08NextAfterRest() {
        var timer = makeTimer()
        timer.start(at: 0)

        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_220) == .endRest)
        #expect(timer.nextBreakAt == 2_420)
        #expect(timer.evaluate(now: 2_420) == .beginRest)
        #expect(timer.breakCount == 2)
    }

    @Test("EB-09 shortening an active rest moves its end earlier")
    func eb09RestDurationChange() {
        var timer = makeTimer(rest: 40)
        timer.start(at: 0)

        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.restEndsAt == 1_240)
        #expect(timer.nextDeadline() == 1_240)

        timer.setRestSeconds(15, at: 1_205)
        #expect(timer.restEndsAt == 1_220)
        #expect(timer.nextDeadline() == 1_220)
        #expect(timer.evaluate(now: 1_219) == .none)
        #expect(timer.evaluate(now: 1_220) == .endRest)
    }
}
