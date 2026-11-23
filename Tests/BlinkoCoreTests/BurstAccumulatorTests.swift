import Testing
import Foundation
@testable import BlinkoCore

@Suite("BurstAccumulator")
struct BurstAccumulatorTests {
    @Test("Valid-face seconds are summed and invalid frames break continuity")
    func validSeconds() throws {
        let accumulator = BurstAccumulator(maxGap: 0.1)
        accumulator.begin(at: 0)

        // 10 s at 30 fps.
        for index in 0..<300 {
            accumulator.record(Fixtures.sample(Double(index) / 30.0, 0.3))
        }

        // A lost face must not count the gap as valid time.
        accumulator.record(Fixtures.sample(10.0, nil, valid: false))
        accumulator.record(Fixtures.sample(10.033, 0.3))
        accumulator.recordBlink()

        let summary = try #require(accumulator.finish(at: 10.1))
        #expect(summary.blinkCount == 1)
        #expect(summary.validSeconds > 9.9 && summary.validSeconds < 10.0)
        #expect(accumulator.startedAt == nil)
    }

    @Test("A stalled gap is capped instead of inflating valid time")
    func cappedGap() throws {
        let accumulator = BurstAccumulator(maxGap: 0.1)
        accumulator.begin(at: 0)
        accumulator.record(Fixtures.sample(0, 0.3))
        accumulator.record(Fixtures.sample(5, 0.3))

        let summary = try #require(accumulator.finish(at: 5))
        #expect(abs(summary.validSeconds - 0.1) < 0.0001)
    }
}
