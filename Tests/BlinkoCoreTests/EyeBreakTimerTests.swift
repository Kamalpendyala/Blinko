import Testing
import Foundation
@testable import BlinkoCore

@Suite("EyeBreakTimer")
struct EyeBreakTimerTests {
    private func makeTimer(
        interval: TimeInterval = 1_200,
        rest: TimeInterval = 20,
        enabled: Bool = true,
        returnDelay: TimeInterval = 60,
        returnCheck: TimeInterval = 5
    ) -> EyeBreakTimer {
        EyeBreakTimer(
            config: EyeBreakTimerConfig(
                enabled: enabled,
                interval: interval,
                restSeconds: rest,
                returnDelay: returnDelay,
                returnCheckSeconds: returnCheck
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
        #expect(timer.nextDeadline(after: 1_200) == 1_220)
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

    @Test("EB-05 a manual break waits for the user before restarting the cadence")
    func eb05ManualBreak() {
        var timer = makeTimer()
        timer.start(at: 0)

        #expect(timer.beginNow(at: 100) == .beginRest)
        #expect(timer.restEndsAt == 120)
        #expect(timer.nextBreakAt == nil)
        #expect(timer.evaluate(now: 120) == .endRest)
        #expect(timer.nextBreakAt == nil)
        #expect(timer.isAwaitingReturn)
        #expect(timer.evaluate(now: 180, presenceDetected: true) == .resumeFocus)
        #expect(timer.nextBreakAt == 1_380)
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
        #expect(timer.nextDeadline(after: 100) == nil)
        #expect(timer.evaluate(now: 9_999) == .none)

        timer.setEnabled(true, at: 10_000)
        #expect(timer.nextBreakAt == 11_200)

        var disabled = makeTimer(enabled: false)
        disabled.start(at: 0)
        #expect(disabled.nextBreakAt == nil)
        #expect(disabled.evaluate(now: 9_999) == .none)
    }

    @Test("EB-08 ending a rest waits for the user, then schedules a full interval")
    func eb08NextAfterRest() {
        var timer = makeTimer()
        timer.start(at: 0)

        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_220) == .endRest)
        #expect(timer.nextBreakAt == nil)
        #expect(timer.evaluate(now: 1_280, presenceDetected: true) == .resumeFocus)
        #expect(timer.nextBreakAt == 2_480)
        #expect(timer.evaluate(now: 2_480) == .beginRest)
        #expect(timer.breakCount == 2)
    }

    @Test("EB-09 shortening an active rest moves its end earlier")
    func eb09RestDurationChange() {
        var timer = makeTimer(rest: 40)
        timer.start(at: 0)

        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.restEndsAt == 1_240)
        #expect(timer.nextDeadline(after: 1_200) == 1_240)

        timer.setRestSeconds(15, at: 1_205)
        #expect(timer.restEndsAt == 1_220)
        #expect(timer.nextDeadline(after: 1_205) == 1_220)
        #expect(timer.evaluate(now: 1_219) == .none)
        #expect(timer.evaluate(now: 1_220) == .endRest)
    }

    @Test("EB-10 presence during the 60 s grace period does not start the timer")
    func eb10ReturnGracePeriod() {
        var timer = makeTimer()
        timer.start(at: 0)

        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_220) == .endRest)
        #expect(timer.resumeNotBefore == 1_280)

        // Present the whole time, but the window has not elapsed.
        #expect(timer.evaluate(now: 1_221, presenceDetected: true) == .none)
        #expect(timer.evaluate(now: 1_279, presenceDetected: true) == .none)
        #expect(timer.nextBreakAt == nil)
        #expect(timer.isAwaitingReturn)

        #expect(timer.evaluate(now: 1_280, presenceDetected: true) == .resumeFocus)
        #expect(timer.nextBreakAt == 2_480)
        #expect(timer.isAwaitingReturn == false)
    }

    @Test("EB-11 time away earns no credit: the full interval starts on return")
    func eb11NoCreditForAbsence() {
        var timer = makeTimer()
        timer.start(at: 0)

        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_220) == .endRest)

        // Away for over an hour; nothing accumulates and no break fires.
        #expect(timer.evaluate(now: 1_280, presenceDetected: false) == .none)
        #expect(timer.evaluate(now: 5_000, presenceDetected: false) == .none)
        #expect(timer.nextBreakAt == nil)
        #expect(timer.isAwaitingReturn)

        #expect(timer.evaluate(now: 5_001, presenceDetected: true) == .resumeFocus)
        #expect(timer.nextBreakAt == 6_201)
        #expect(timer.breakCount == 1)
    }

    @Test("EB-12 the monitor re-checks at the grace period, then every check interval")
    func eb12ReturnDeadlines() {
        var timer = makeTimer()
        timer.start(at: 0)
        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_220) == .endRest)

        #expect(timer.nextDeadline(after: 1_220) == 1_280)
        #expect(timer.nextDeadline(after: 1_280) == 1_285)
        #expect(timer.nextDeadline(after: 1_300) == 1_305)
    }

    @Test("EB-13 suppression during the wait reschedules a full interval")
    func eb13SuppressionWhileWaiting() {
        var timer = makeTimer()
        timer.start(at: 0)
        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_220) == .endRest)

        #expect(timer.evaluate(now: 1_280, suppression: .quietHours) == .suppressed(.quietHours))
        #expect(timer.isAwaitingReturn == false)
        #expect(timer.nextBreakAt == 2_480)
    }

    @Test("EB-13b the idle gate does not cancel the wait for the user to return")
    func eb13bIdleDoesNotCancelWait() {
        var timer = makeTimer()
        timer.start(at: 0)
        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_220) == .endRest)

        // Away long enough for the idle gate; the timer must keep waiting.
        #expect(timer.evaluate(now: 1_280, suppression: .userIdle) == .none)
        #expect(timer.isAwaitingReturn)
        #expect(timer.nextBreakAt == nil)

        #expect(timer.evaluate(
            now: 1_290,
            suppression: .userIdle,
            presenceDetected: true
        ) == .resumeFocus)
        #expect(timer.nextBreakAt == 2_490)
    }

    @Test("EB-14 the grace period is measured from the rest end, not a late wake")
    func eb14LateEvaluation() {
        var timer = makeTimer()
        timer.start(at: 0)
        #expect(timer.evaluate(now: 1_200) == .beginRest)

        // The wake lands 10 s late; the user still gets the full 60 s.
        #expect(timer.evaluate(now: 1_230) == .endRest)
        #expect(timer.resumeNotBefore == 1_280)
        #expect(timer.evaluate(now: 1_279, presenceDetected: true) == .none)
        #expect(timer.evaluate(now: 1_280, presenceDetected: true) == .resumeFocus)
    }

    @Test("EB-15 disabling breaks clears the pending return")
    func eb15DisableWhileWaiting() {
        var timer = makeTimer()
        timer.start(at: 0)
        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_220) == .endRest)
        #expect(timer.isAwaitingReturn)

        timer.setEnabled(false, at: 1_230)
        #expect(timer.isAwaitingReturn == false)
        #expect(timer.nextBreakAt == nil)
        #expect(timer.nextDeadline(after: 1_230) == nil)
        #expect(timer.evaluate(now: 9_999, presenceDetected: true) == .none)
    }

    @Test("EB-16 a zero grace period starts on presence at the rest end")
    func eb16ZeroGrace() {
        var timer = makeTimer(returnDelay: 0)
        timer.start(at: 0)
        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_220) == .endRest)
        #expect(timer.resumeNotBefore == 1_220)
        #expect(timer.evaluate(now: 1_220, presenceDetected: true) == .resumeFocus)
        #expect(timer.nextBreakAt == 2_420)
    }

    @Test("EB-17 starting the timer clears any pending return")
    func eb17StartClearsWaiting() {
        var timer = makeTimer()
        timer.start(at: 0)
        #expect(timer.evaluate(now: 1_200) == .beginRest)
        #expect(timer.evaluate(now: 1_220) == .endRest)
        #expect(timer.isAwaitingReturn)

        timer.start(at: 2_000)
        #expect(timer.isAwaitingReturn == false)
        #expect(timer.nextBreakAt == 3_200)
    }
}

@Suite("ReturnPresence")
struct ReturnPresenceTests {
    private let presence = ReturnPresence(faceWindow: 2, inputWindow: 6)

    @Test("EB-18 a recent camera face counts as present without input")
    func eb18FacePresent() {
        #expect(presence.isPresent(now: 100, lastValidFaceAt: 99, secondsSinceInput: 500))
    }

    @Test("EB-19 keyboard/mouse activity is the fallback when no face is seen")
    func eb19InputFallback() {
        #expect(presence.isPresent(now: 100, lastValidFaceAt: nil, secondsSinceInput: 3))
        #expect(presence.isPresent(now: 100, lastValidFaceAt: 10, secondsSinceInput: 0))
    }

    @Test("EB-20 a stale face and stale input means the user is away")
    func eb20Absent() {
        #expect(presence.isPresent(now: 100, lastValidFaceAt: 90, secondsSinceInput: 60) == false)
    }

    @Test("EB-21 unknown idle time is not treated as activity")
    func eb21UnknownInput() {
        #expect(presence.isPresent(
            now: 100,
            lastValidFaceAt: nil,
            secondsSinceInput: nil
        ) == false)
    }

    @Test("EB-22 the face window boundary is inclusive")
    func eb22WindowBoundaries() {
        #expect(presence.isPresent(now: 100, lastValidFaceAt: 98, secondsSinceInput: nil))
        #expect(presence.isPresent(now: 100, lastValidFaceAt: 97.9, secondsSinceInput: nil) == false)
        #expect(presence.isPresent(now: 100, lastValidFaceAt: nil, secondsSinceInput: 6))
        #expect(presence.isPresent(now: 100, lastValidFaceAt: nil, secondsSinceInput: 6.1) == false)
    }
}
