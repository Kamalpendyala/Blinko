import Testing
import Foundation
@testable import BlinkoCore

@Suite("BurstGate")
struct BurstGateTests {
    private let gate = BurstGate()

    @Test("SC-08 an unplugged Mac below 20% skips bursts; AC power resumes them")
    func sc08LowBattery() {
        var conditions = BurstConditions(batteryLevel: 0.15, isPluggedIn: false)
        #expect(gate.suppression(for: conditions).contains(.lowBattery))
        #expect(gate.canRunBurst(conditions) == false)

        conditions.isPluggedIn = true
        #expect(gate.canRunBurst(conditions))

        conditions.batteryLevel = 0.20
        conditions.isPluggedIn = false
        #expect(gate.canRunBurst(conditions))

        conditions.batteryLevel = 0.19
        #expect(gate.canRunBurst(conditions) == false)
    }

    @Test("SC-09 a user idle beyond the threshold skips bursts")
    func sc09UserIdle() {
        var conditions = BurstConditions(secondsSinceInput: 301, idleThreshold: 300)
        #expect(gate.suppression(for: conditions).contains(.userIdle))
        #expect(gate.canRunBurst(conditions) == false)

        conditions.secondsSinceInput = 10
        #expect(gate.canRunBurst(conditions))

        conditions.secondsSinceInput = nil
        #expect(gate.canRunBurst(conditions))
    }

    @Test("NP-06 fullscreen, Focus and screen sharing suppress reminders")
    func presentationSuppression() {
        var conditions = BurstConditions()
        conditions.isFullscreen = true
        #expect(gate.suppression(for: conditions) == [.fullscreen])
        #expect(gate.canRunBurst(conditions) == false)

        conditions.isFullscreen = false
        conditions.isDoNotDisturb = true
        #expect(gate.suppression(for: conditions) == [.doNotDisturb])

        conditions.isDoNotDisturb = false
        conditions.isScreenSharing = true
        #expect(gate.suppression(for: conditions) == [.screenSharing])
    }

    @Test("pause, lock, sleep, camera denial and quiet hours all suppress bursts")
    func hardSuppression() {
        #expect(gate.suppression(for: BurstConditions(isPaused: true)) == [.paused])
        #expect(gate.suppression(for: BurstConditions(isScreenLocked: true)) == [.screenLocked])
        #expect(gate.suppression(for: BurstConditions(isAsleep: true)) == [.asleep])
        #expect(gate.suppression(for: BurstConditions(cameraDenied: true)) == [.cameraUnavailable])
        #expect(gate.suppression(for: BurstConditions(quietHoursActive: true)) == [.quietHours])

        let all = BurstConditions(
            isPaused: true,
            cameraDenied: true,
            isAsleep: true,
            isScreenLocked: true,
            isFullscreen: true,
            isDoNotDisturb: true,
            isScreenSharing: true,
            quietHoursActive: true,
            secondsSinceInput: 600,
            batteryLevel: 0.1,
            isPluggedIn: false
        )
        let suppression = gate.suppression(for: all)
        for flag in [
            NudgeSuppression.paused, .cameraUnavailable, .asleep, .screenLocked,
            .fullscreen, .doNotDisturb, .screenSharing, .quietHours, .userIdle, .lowBattery,
        ] {
            #expect(suppression.contains(flag))
        }
        #expect(gate.canRunBurst(all) == false)
    }

    @Test("a normal active desktop machine is eligible for a burst")
    func eligible() {
        let conditions = BurstConditions(
            secondsSinceInput: 12,
            idleThreshold: 300,
            batteryLevel: 0.85,
            isPluggedIn: false
        )
        #expect(gate.suppression(for: conditions).isEmpty)
        #expect(gate.canRunBurst(conditions))
    }
}
