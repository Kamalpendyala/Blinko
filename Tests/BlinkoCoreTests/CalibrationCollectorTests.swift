import Testing
@testable import BlinkoCore

@Suite("Calibration")
struct CalibrationCollectorTests {
    @Test("Median of enough samples becomes the baseline")
    func medianBaseline() {
        let collector = CalibrationCollector(minSamples: 3, maxSamples: 10)
        for value in [0.28, 0.30, 0.32] {
            collector.add(openness: value)
        }

        let result = collector.finish()
        #expect(result.isValid)
        #expect(abs((result.baseline ?? 0) - 0.30) < 0.000_001)
        #expect(result.sampleCount == 3)
    }

    @Test("Too few valid samples is rejected")
    func tooFewSamples() {
        let collector = CalibrationCollector(minSamples: 15)
        collector.add(openness: 0.30)
        collector.add(openness: 0.31)

        let result = collector.finish()
        #expect(!result.isValid)
        #expect(result.baseline == nil)
        #expect(result.sampleCount == 2)
    }

    @Test("Invalid samples are ignored and the window is bounded")
    func invalidSamples() {
        let collector = CalibrationCollector(minSamples: 1, maxSamples: 3)
        collector.add(openness: .nan)
        collector.add(openness: -1)
        collector.add(openness: 0)
        collector.add(openness: 1.4)
        collector.add(openness: .infinity)
        #expect(collector.sampleCount == 0)

        for value in [0.1, 0.2, 0.3, 0.4] {
            collector.add(openness: value)
        }
        #expect(collector.sampleCount == 3)
        #expect(collector.samples == [0.2, 0.3, 0.4])
    }
}
