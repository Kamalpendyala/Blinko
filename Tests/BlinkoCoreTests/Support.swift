import Foundation
import CoreGraphics
@testable import BlinkoCore

enum Fixtures {
    static let defaultBox = CGRect(x: 0.25, y: 0.25, width: 0.3, height: 0.4)

    /// Six-point contour in Vision order: corner, top, top, corner, bottom, bottom.
    /// `ratio` is exactly the openness ratio the metrics should compute.
    static func eyeContour(
        ratio: Double,
        center: CGPoint,
        width: Double = 0.1
    ) -> [CGPoint] {
        let height = ratio * width
        return [
            CGPoint(x: center.x - width / 2, y: center.y),
            CGPoint(x: center.x - width / 4, y: center.y + height / 2),
            CGPoint(x: center.x + width / 4, y: center.y + height / 2),
            CGPoint(x: center.x + width / 2, y: center.y),
            CGPoint(x: center.x + width / 4, y: center.y - height / 2),
            CGPoint(x: center.x - width / 4, y: center.y - height / 2),
        ]
    }

    static func observation(
        timestamp: TimeInterval,
        ratio: Double,
        faceFound: Bool = true,
        box: CGRect = defaultBox,
        yaw: Double? = 0,
        roll: Double? = 0,
        leftEye: [CGPoint]? = nil,
        rightEye: [CGPoint]? = nil
    ) -> FaceObservation {
        FaceObservation(
            timestamp: timestamp,
            faceFound: faceFound,
            leftEye: leftEye ?? eyeContour(ratio: ratio, center: CGPoint(x: 0.36, y: 0.5)),
            rightEye: rightEye ?? eyeContour(ratio: ratio, center: CGPoint(x: 0.64, y: 0.5)),
            faceBoundingBox: box,
            yaw: yaw,
            roll: roll
        )
    }

    static func sample(
        _ timestamp: TimeInterval,
        _ openness: Double?,
        valid: Bool = true
    ) -> EyeSample {
        EyeSample(
            timestamp: timestamp,
            openness: openness,
            valid: valid,
            reason: valid ? nil : .noFace
        )
    }

    static func calibratedDetector(
        baseline: Double = 0.30,
        config: BlinkDetectorConfig = BlinkDetectorConfig()
    ) -> BlinkDetector {
        let detector = BlinkDetector(config: config)
        detector.calibrate(with: Array(repeating: baseline, count: 30))
        return detector
    }

    /// Synthetic but realistic 30 fps session with labelled blinks.
    static func syntheticSession(
        duration: TimeInterval,
        blinkTimes: [TimeInterval],
        fps: Double = 30
    ) -> [FaceObservation] {
        let frameCount = Int(duration * fps)
        let dt = 1.0 / fps
        let blinkStarts = blinkTimes.map { Int(($0 * fps).rounded()) }
        let blinkLength = 4

        var observations: [FaceObservation] = []
        observations.reserveCapacity(frameCount)

        for index in 0..<frameCount {
            let timestamp = Double(index) * dt
            let inBlink = blinkStarts.contains { index >= $0 && index < $0 + blinkLength }
            let noise = 0.006 * sin(Double(index) * 0.9) + 0.003 * cos(Double(index) * 2.3)
            let ratio = inBlink ? 0.02 : max(0.05, 0.30 + noise)

            // Occasional dropped face, never close enough to break a labelled blink.
            let nearBlink = blinkStarts.contains { abs(index - $0) <= 8 }
            let faceFound = nearBlink || index % 97 != 0

            observations.append(
                observation(
                    timestamp: timestamp,
                    ratio: ratio,
                    faceFound: faceFound
                )
            )
        }

        return observations
    }
}
