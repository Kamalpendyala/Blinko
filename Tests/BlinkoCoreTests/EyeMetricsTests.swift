import Testing
import Foundation
import CoreGraphics
@testable import BlinkoCore

@Suite("EyeMetrics")
struct EyeMetricsTests {
    let metrics = EyeMetrics()

    @Test("EM-01 fully open contour yields an open-range ratio")
    func em01OpenContour() throws {
        let sample = metrics.evaluate(Fixtures.observation(timestamp: 0, ratio: 0.32))

        #expect(sample.valid)
        let openness = try #require(sample.openness)
        #expect(openness > 0.25 && openness < 0.40)
        #expect(sample.reason == nil)
    }

    @Test("EM-02 closed contour yields a ratio near zero")
    func em02ClosedContour() throws {
        let sample = metrics.evaluate(Fixtures.observation(timestamp: 0, ratio: 0.004))

        #expect(sample.valid)
        let openness = try #require(sample.openness)
        #expect(openness >= 0)
        #expect(openness < 0.05)
    }

    @Test("EM-03 zero-width landmarks are invalid and never NaN")
    func em03DegenerateLandmarks() throws {
        let center = CGPoint(x: 0.5, y: 0.5)
        let zeroWidth = Fixtures.eyeContour(ratio: 0.3, center: center, width: 0)

        let sample = metrics.evaluate(
            Fixtures.observation(
                timestamp: 0,
                ratio: 0.3,
                leftEye: zeroWidth,
                rightEye: zeroWidth
            )
        )

        #expect(!sample.valid)
        #expect(sample.reason == .degenerateLandmarks)
        #expect(sample.openness == nil)

        let nanPoints = [
            CGPoint(x: .nan, y: 0.5),
            CGPoint(x: 0.4, y: 0.6),
            CGPoint(x: 0.6, y: 0.6),
        ]
        let nanSample = metrics.evaluate(
            Fixtures.observation(timestamp: 0, ratio: 0.3, leftEye: nanPoints, rightEye: nanPoints)
        )
        #expect(!nanSample.valid)
        #expect(nanSample.openness == nil)
    }

    @Test("EM-04 missing or asymmetric eyes invalidate the frame")
    func em04AsymmetricEyes() {
        let missing = metrics.evaluate(
            Fixtures.observation(timestamp: 0, ratio: 0.3, rightEye: [])
        )
        #expect(!missing.valid)
        #expect(missing.reason == .missingEye)

        let asymmetric = metrics.evaluate(
            Fixtures.observation(
                timestamp: 0,
                ratio: 0.3,
                leftEye: Fixtures.eyeContour(ratio: 0.35, center: CGPoint(x: 0.36, y: 0.5)),
                rightEye: Fixtures.eyeContour(ratio: 0.02, center: CGPoint(x: 0.64, y: 0.5))
            )
        )
        #expect(!asymmetric.valid)
        #expect(asymmetric.reason == .asymmetricEyes)
    }

    @Test("EM-05 tiny or rotated faces are invalid")
    func em05FaceTooSmallOrRotated() {
        let tiny = metrics.evaluate(
            Fixtures.observation(
                timestamp: 0,
                ratio: 0.3,
                box: CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.05)
            )
        )
        #expect(!tiny.valid)
        #expect(tiny.reason == .faceTooSmall)

        let yawed = metrics.evaluate(Fixtures.observation(timestamp: 0, ratio: 0.3, yaw: 0.6))
        #expect(!yawed.valid)
        #expect(yawed.reason == .faceRotated)

        let rolled = metrics.evaluate(Fixtures.observation(timestamp: 0, ratio: 0.3, roll: 0.7))
        #expect(!rolled.valid)
        #expect(rolled.reason == .faceRotated)
    }

    @Test("No face is reported without touching the ratios")
    func noFaceIsInvalid() {
        let sample = metrics.evaluate(.noFace(timestamp: 1.5))
        #expect(!sample.valid)
        #expect(sample.reason == .noFace)
        #expect(sample.openness == nil)
    }
}
