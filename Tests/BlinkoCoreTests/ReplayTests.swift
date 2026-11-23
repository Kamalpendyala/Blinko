import Testing
import Foundation
@testable import BlinkoCore

@Suite("Replay and CSV")
struct ReplayTests {
    @Test("CSV encode/decode round-trips landmark data")
    func csvRoundTrip() throws {
        let observations = [
            Fixtures.observation(timestamp: 1.234567, ratio: 0.30),
            .noFace(timestamp: 1.267890),
            Fixtures.observation(timestamp: 1.301234, ratio: 0.05, yaw: -0.12, roll: 0.03),
        ]

        let text = LandmarkCSV.encode(observations)
        let decoded = try LandmarkCSV.decode(text)

        #expect(decoded.count == observations.count)
        #expect(decoded[1].faceFound == false)
        #expect(decoded[2].yaw != nil)
        // Exact re-encode proves every field survived the round trip.
        #expect(LandmarkCSV.encode(decoded) == text)
    }

    @Test("Malformed CSV rows throw with a line number")
    func malformedRow() {
        let csv = """
        timestamp,faceFound,bboxX,bboxY,bboxW,bboxH,yaw,roll,leftEye,rightEye
        0.0,1,0.25,0.25,0.3,0.4,0,0,0.3 0.5 0.4 0.5
        """

        #expect(throws: LandmarkCSV.DecodeError.self) {
            try LandmarkCSV.decode(csv)
        }
    }

    @Test("An empty replay file refuses to start")
    func emptyReplay() throws {
        let source = try ReplayFrameSource(csv: LandmarkCSV.header + "\n")
        #expect(throws: ReplayFrameSource.ReplayError.self) {
            try source.start()
        }
    }

    @Test("BD-10 replaying a recorded session CSV recovers the labelled blink count")
    func bd10ReplayRecordedSession() throws {
        let observations = Fixtures.syntheticSession(duration: 20, blinkTimes: [5, 10, 15])
        let csv = LandmarkCSV.encode(observations)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blinko-session-\(UUID().uuidString).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try ReplayFrameSource(contentsOf: url, pace: false)
        var replayed: [FaceObservation] = []
        source.onFrame = { replayed.append($0) }
        try source.start()

        #expect(replayed.count == observations.count)

        let metrics = EyeMetrics()
        let detector = Fixtures.calibratedDetector()
        for observation in replayed {
            detector.process(metrics.evaluate(observation))
        }

        // Hand-labelled truth is 3; spec allows ±1.
        #expect(abs(detector.blinkCount - 3) <= 1)
    }
}

@Suite("Clock")
struct ClockTests {
    @Test("FakeClock advances wall and monotonic time together")
    func advance() {
        let clock = FakeClock()
        let monotonicStart = clock.monotonicNow
        let wallStart = clock.now

        clock.advance(by: 60)

        #expect(clock.monotonicNow == monotonicStart + 60)
        #expect(clock.now == wallStart.addingTimeInterval(60))
    }

    @Test("Wall-clock jumps leave the monotonic clock alone")
    func wallClockJump() {
        let clock = FakeClock()
        let monotonicStart = clock.monotonicNow

        clock.setWallClock(clock.now.addingTimeInterval(-7_200))

        #expect(clock.monotonicNow == monotonicStart)
    }
}
