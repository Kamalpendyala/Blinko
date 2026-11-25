import Testing
import Foundation
@testable import BlinkoCore

@Suite("RateEstimator")
struct RateEstimatorTests {
    private func burst(validSeconds: Double, blinks: Int) -> BurstSummary {
        BurstSummary(
            startedAt: 0,
            endedAt: max(validSeconds, 12),
            validSeconds: validSeconds,
            blinkCount: blinks
        )
    }

    @Test("RE-01 a 12 s burst with 3 blinks is 15/min")
    func re01TwelveSecondBurst() {
        let estimator = RateEstimator()
        let update = estimator.ingest(burst(validSeconds: 12, blinks: 3))

        #expect(update.accepted)
        #expect(update.burstRate == 15)
        #expect(estimator.smoothedRate == 15)
        #expect(estimator.acceptedBursts == 1)
    }

    @Test("RE-02 the rate uses valid-face seconds only")
    func re02ValidSecondsOnly() {
        let estimator = RateEstimator()
        // 4 s of face time inside a 12 s burst: 2 blinks / 4 s = 30/min.
        let update = estimator.ingest(burst(validSeconds: 4, blinks: 2))

        #expect(update.accepted)
        #expect(update.burstRate == 30)
        #expect(estimator.smoothedRate == 30)
    }

    @Test("RE-03 a burst with under 3 s valid face is discarded")
    func re03DiscardsShortBurst() {
        let estimator = RateEstimator()
        estimator.ingest(burst(validSeconds: 12, blinks: 3))

        let update = estimator.ingest(burst(validSeconds: 2.9, blinks: 0))

        #expect(update.accepted == false)
        #expect(update.burstRate == nil)
        #expect(estimator.smoothedRate == 15)
        #expect(estimator.discardedBursts == 1)
    }

    @Test("RE-04 the EMA matches hand-computed values")
    func re04EMA() throws {
        let estimator = RateEstimator(
            config: RateEstimatorConfig(minValidSeconds: 3, smoothing: 0.3)
        )

        estimator.ingest(burst(validSeconds: 12, blinks: 3)) // 15
        estimator.ingest(burst(validSeconds: 12, blinks: 6)) // 30
        // 15 + 0.3 × (30 − 15) = 19.5
        #expect(abs(try #require(estimator.smoothedRate) - 19.5) < 0.0001)

        estimator.ingest(burst(validSeconds: 12, blinks: 0)) // 0
        // 19.5 + 0.3 × (0 − 19.5) = 13.65
        #expect(abs(try #require(estimator.smoothedRate) - 13.65) < 0.0001)
    }
}
