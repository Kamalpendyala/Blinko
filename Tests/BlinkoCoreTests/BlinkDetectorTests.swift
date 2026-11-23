import Testing
import Foundation
@testable import BlinkoCore

@Suite("BlinkDetector")
struct BlinkDetectorTests {
    @Test("BD-01 open → 3 closed frames → open counts exactly one blink")
    func bd01ThreeClosedFrames() {
        let detector = Fixtures.calibratedDetector()
        var callbacks = 0
        detector.onBlink = { _ in callbacks += 1 }

        let sequence: [(TimeInterval, Double)] = [
            (0.000, 0.30),
            (0.033, 0.05),
            (0.066, 0.05),
            (0.099, 0.05),
            (0.132, 0.30),
        ]
        for (timestamp, openness) in sequence {
            detector.process(Fixtures.sample(timestamp, openness))
        }

        #expect(detector.blinkCount == 1)
        #expect(callbacks == 1)
    }

    @Test("BD-02 a single closed frame is noise, not a blink")
    func bd02SingleClosedFrame() {
        let detector = Fixtures.calibratedDetector()

        for (timestamp, openness) in [(0.000, 0.30), (0.033, 0.05), (0.066, 0.30)] {
            detector.process(Fixtures.sample(timestamp, openness))
        }

        #expect(detector.blinkCount == 0)
        #expect(detector.closureEpisodeCount == 1)
    }

    @Test("BD-03 a 600 ms closure is eyes shut, not a blink")
    func bd03LongClosure() {
        let detector = Fixtures.calibratedDetector()
        detector.process(Fixtures.sample(0.000, 0.30))

        var timestamp = 0.033
        while timestamp <= 0.600 + 0.0001 {
            detector.process(Fixtures.sample(timestamp, 0.05))
            timestamp += 0.033
        }
        detector.process(Fixtures.sample(timestamp, 0.30))

        #expect(detector.blinkCount == 0)
    }

    @Test("BD-04 two blinks 200 ms apart count as two")
    func bd04TwoBlinks() {
        let detector = Fixtures.calibratedDetector()

        let sequence: [(TimeInterval, Double)] = [
            (0.000, 0.30),
            (0.033, 0.05), (0.066, 0.05), (0.099, 0.05),
            (0.132, 0.30),
            (0.200, 0.05), (0.233, 0.05), (0.266, 0.05),
            (0.299, 0.30),
        ]
        for (timestamp, openness) in sequence {
            detector.process(Fixtures.sample(timestamp, openness))
        }

        #expect(detector.blinkCount == 2)
    }

    @Test("BD-05 values inside the hysteresis band do not flap")
    func bd05Hysteresis() {
        let detector = Fixtures.calibratedDetector(baseline: 0.30)
        detector.process(Fixtures.sample(0.000, 0.30))

        var timestamp = 0.033
        let hovering: [Double] = [
            0.19, 0.21, 0.22, 0.23, 0.235, 0.23, 0.22, 0.21, 0.20, 0.19,
            0.20, 0.21, 0.22, 0.23, 0.235, 0.23, 0.22, 0.21, 0.20, 0.19,
        ]
        for openness in hovering {
            detector.process(Fixtures.sample(timestamp, openness))
            timestamp += 0.033
        }
        detector.process(Fixtures.sample(timestamp, 0.30))

        #expect(detector.closureEpisodeCount == 1)
        #expect(detector.blinkCount == 0)
    }

    @Test("BD-06 losing the face mid-closure discards the blink and resets state")
    func bd06FaceLostMidClosure() {
        let detector = Fixtures.calibratedDetector()

        detector.process(Fixtures.sample(0.000, 0.30))
        detector.process(Fixtures.sample(0.033, 0.05))
        detector.process(Fixtures.sample(0.066, 0.05))
        detector.process(Fixtures.sample(0.099, nil, valid: false))
        detector.process(Fixtures.sample(0.132, 0.30))
        #expect(detector.blinkCount == 0)

        detector.process(Fixtures.sample(0.165, 0.05))
        detector.process(Fixtures.sample(0.198, 0.05))
        detector.process(Fixtures.sample(0.231, 0.05))
        detector.process(Fixtures.sample(0.264, 0.30))
        #expect(detector.blinkCount == 1)
    }

    @Test("BD-07 slow baseline drift adapts without false blinks")
    func bd07BaselineDrift() throws {
        let detector = Fixtures.calibratedDetector(baseline: 0.30)
        let frameCount = 9_000
        let dt = 1.0 / 30.0
        var timestamp = 0.0

        for index in 0..<frameCount {
            let progress = Double(index) / Double(frameCount)
            let openness = 0.30 - 0.10 * progress + 0.004 * sin(Double(index) * 0.7)
            detector.process(Fixtures.sample(timestamp, openness))
            timestamp += dt
        }

        #expect(detector.blinkCount == 0)
        let baseline = try #require(detector.baseline)
        #expect(baseline > 0.18 && baseline < 0.22)
    }

    @Test("BD-08 frame gaps up to 100 ms still allow a blink")
    func bd08FrameDrops() {
        let detector = Fixtures.calibratedDetector()

        let sequence: [(TimeInterval, Double)] = [
            (0.000, 0.30),
            (0.033, 0.05),
            (0.133, 0.05), // 100 ms gap
            (0.166, 0.05),
            (0.199, 0.30),
        ]
        for (timestamp, openness) in sequence {
            detector.process(Fixtures.sample(timestamp, openness))
        }

        #expect(detector.blinkCount == 1)
    }

    @Test("BD-09 duplicate and out-of-order timestamps are ignored safely")
    func bd09TimestampDisorder() {
        let detector = Fixtures.calibratedDetector()

        let sequence: [(TimeInterval, Double)] = [
            (1.000, 0.30),
            (1.033, 0.05),
            (1.033, 0.05), // duplicate
            (1.050, 0.05),
            (1.020, 0.05), // out of order
            (0.900, 0.30), // far out of order
            (1.066, 0.30),
        ]
        for (timestamp, openness) in sequence {
            detector.process(Fixtures.sample(timestamp, openness))
        }

        #expect(detector.blinkCount == 1)
    }
}
