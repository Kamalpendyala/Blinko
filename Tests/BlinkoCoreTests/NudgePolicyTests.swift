import Testing
import Foundation
@testable import BlinkoCore

@Suite("NudgePolicy")
struct NudgePolicyTests {
    @Test("NP-01 a low rate for two bursts only does not nudge")
    func np01TwoLowBursts() {
        let policy = NudgePolicy()

        #expect(policy.evaluate(rate: 5, now: 0) == .none)
        #expect(policy.evaluate(rate: 5, now: 60) == .none)
        #expect(policy.nudgeCount == 0)
        #expect(policy.lowStreak == 2)
    }

    @Test("NP-02 a low rate for three bursts nudges once")
    func np02ThreeLowBursts() {
        let policy = NudgePolicy()

        #expect(policy.evaluate(rate: 5, now: 0) == .none)
        #expect(policy.evaluate(rate: 5, now: 60) == .none)
        #expect(policy.evaluate(rate: 5, now: 120) == .nudge(.lowRate))
        #expect(policy.nudgeCount == 1)
    }

    @Test("NP-03 a continuing low rate does not nudge during cooldown")
    func np03Cooldown() {
        let policy = NudgePolicy()

        policy.evaluate(rate: 5, now: 0)
        policy.evaluate(rate: 5, now: 60)
        #expect(policy.evaluate(rate: 5, now: 120) == .nudge(.lowRate))

        #expect(policy.evaluate(rate: 5, now: 180) == .cooldown)
        #expect(policy.evaluate(rate: 5, now: 719) == .cooldown)
        #expect(policy.nudgeCount == 1)

        // Exactly 600 s after the first nudge the cooldown is over.
        #expect(policy.evaluate(rate: 5, now: 720) == .nudge(.lowRate))
        #expect(policy.nudgeCount == 2)
    }

    @Test("NP-04 a fourth trigger inside an hour is suppressed")
    func np04HourlyLimit() {
        let policy = NudgePolicy()

        // Three nudges: 120, 720 and 1320 (each after a 600 s cooldown).
        var now: TimeInterval = 0
        for _ in 0..<3 {
            policy.evaluate(rate: 5, now: now)
            policy.evaluate(rate: 5, now: now + 60)
            policy.evaluate(rate: 5, now: now + 120)
            now += 600
        }

        #expect(policy.nudgeCount == 3)
        // Cooldown has elapsed, but all three nudges are still inside the hour.
        #expect(policy.evaluate(rate: 5, now: 1920) == .hourlyLimit)
        #expect(policy.nudgeCount == 3)
    }

    @Test("NP-05 rate recovery resets the low-streak counter")
    func np05Recovery() {
        let policy = NudgePolicy()

        #expect(policy.evaluate(rate: 5, now: 0) == .none)
        #expect(policy.evaluate(rate: 5, now: 60) == .none)
        #expect(policy.evaluate(rate: 12, now: 120) == .none)
        #expect(policy.lowStreak == 0)

        #expect(policy.evaluate(rate: 5, now: 180) == .none)
        #expect(policy.evaluate(rate: 5, now: 240) == .none)
        #expect(policy.nudgeCount == 0)
        #expect(policy.evaluate(rate: 5, now: 300) == .nudge(.lowRate))
    }

    @Test("NP-06 suppression never nudges and clears the streak")
    func np06Suppression() {
        let suppressions: [NudgeSuppression] = [
            .paused,
            .quietHours,
            .fullscreen,
            .doNotDisturb,
            .screenSharing,
            .screenLocked,
            .lowBattery,
            .userIdle,
        ]

        for suppression in suppressions {
            let policy = NudgePolicy()
            policy.evaluate(rate: 5, now: 0)
            policy.evaluate(rate: 5, now: 60)

            #expect(policy.evaluate(rate: 5, now: 120, suppression: suppression) == .suppressed(suppression))
            #expect(policy.nudgeCount == 0)
            #expect(policy.lowStreak == 0)
        }

        // A combined suppression set is reported as-is.
        let policy = NudgePolicy()
        policy.evaluate(rate: 5, now: 0)
        policy.evaluate(rate: 5, now: 60)
        #expect(
            policy.evaluate(rate: 5, now: 120, suppression: [.paused, .quietHours])
                == .suppressed([.paused, .quietHours])
        )
    }

}
