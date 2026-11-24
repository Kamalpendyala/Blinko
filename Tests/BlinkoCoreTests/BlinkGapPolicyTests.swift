import Testing
import Foundation
@testable import BlinkoCore

@Suite("BlinkGapPolicy")
struct BlinkGapPolicyTests {
    @Test("GAP-01 fires after the interval with no blink")
    func gap01Fires() {
        let policy = BlinkGapPolicy(config: BlinkGapPolicyConfig(interval: 5))
        policy.start(at: 0)

        #expect(policy.evaluate(now: 4.5, facePresent: true) == .none)
        #expect(policy.evaluate(now: 5, facePresent: true) == .nudge(.noBlink))
        #expect(policy.nudgeCount == 1)
    }

    @Test("GAP-02 a blink restarts the countdown")
    func gap02BlinkResets() {
        let policy = BlinkGapPolicy(config: BlinkGapPolicyConfig(interval: 5))
        policy.start(at: 0)

        policy.recordBlink(at: 4)
        #expect(policy.evaluate(now: 8.9, facePresent: true) == .none)
        #expect(policy.evaluate(now: 9, facePresent: true) == .nudge(.noBlink))
    }

    @Test("GAP-03 repeats every interval while blinking stays absent")
    func gap03Repeats() {
        let policy = BlinkGapPolicy(config: BlinkGapPolicyConfig(interval: 5))
        policy.start(at: 0)

        #expect(policy.evaluate(now: 5, facePresent: true) == .nudge(.noBlink))
        #expect(policy.evaluate(now: 9.9, facePresent: true) == .none)
        #expect(policy.evaluate(now: 10, facePresent: true) == .nudge(.noBlink))
        #expect(policy.evaluate(now: 15, facePresent: true) == .nudge(.noBlink))
        #expect(policy.nudgeCount == 3)
    }

    @Test("GAP-04 no face means no reminder and a fresh countdown")
    func gap04NoFace() {
        let policy = BlinkGapPolicy(config: BlinkGapPolicyConfig(interval: 5))
        policy.start(at: 0)

        #expect(policy.evaluate(now: 4, facePresent: false) == .none)
        #expect(policy.evaluate(now: 8.9, facePresent: true) == .none)
        #expect(policy.evaluate(now: 9, facePresent: true) == .nudge(.noBlink))
    }

    @Test("GAP-05 pause or quiet hours suppress and re-arm")
    func gap05Suppression() {
        let policy = BlinkGapPolicy(config: BlinkGapPolicyConfig(interval: 5))
        policy.start(at: 0)

        #expect(
            policy.evaluate(now: 4, facePresent: true, suppression: [.paused])
                == .suppressed([.paused])
        )
        #expect(policy.evaluate(now: 8.9, facePresent: true) == .none)
        #expect(policy.evaluate(now: 9, facePresent: true) == .nudge(.noBlink))
    }

    @Test("GAP-06 reset clears the watchdog")
    func gap06Reset() {
        let policy = BlinkGapPolicy(config: BlinkGapPolicyConfig(interval: 5))
        policy.start(at: 0)
        #expect(policy.evaluate(now: 5, facePresent: true) == .nudge(.noBlink))

        policy.reset()
        #expect(policy.lastBlinkAt == nil)
        #expect(policy.nudgeCount == 0)
        #expect(policy.evaluate(now: 10, facePresent: true) == .none)
    }
}
