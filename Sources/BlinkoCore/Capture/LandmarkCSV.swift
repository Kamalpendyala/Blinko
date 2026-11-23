import Foundation
import CoreGraphics

/// CSV transport for recorded landmark sessions.
///
/// This is derived data only — eye-contour points, a face box and pose angles.
/// No pixels are ever written. Used by the replay harness and the debug-only
/// recorder (`--record`).
public enum LandmarkCSV {
    public static let header = "timestamp,faceFound,bboxX,bboxY,bboxW,bboxH,yaw,roll,leftEye,rightEye"

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case malformedRow(line: Int, reason: String)

        public var description: String {
            switch self {
            case let .malformedRow(line, reason):
                return "CSV line \(line): \(reason)"
            }
        }
    }

    public static func encode(_ observations: [FaceObservation]) -> String {
        var lines = [header]
        lines.append(contentsOf: observations.map(encodeLine))
        return lines.joined(separator: "\n") + "\n"
    }

    public static func encodeLine(_ observation: FaceObservation) -> String {
        let box = observation.faceBoundingBox
        let fields: [String] = [
            format(observation.timestamp),
            observation.faceFound ? "1" : "0",
            format(Double(box.origin.x)),
            format(Double(box.origin.y)),
            format(Double(box.width)),
            format(Double(box.height)),
            observation.yaw.map(format) ?? "",
            observation.roll.map(format) ?? "",
            encodeEye(observation.leftEye),
            encodeEye(observation.rightEye),
        ]
        return fields.joined(separator: ",")
    }

    public static func decode(_ text: String) throws -> [FaceObservation] {
        var observations: [FaceObservation] = []
        var sawFirstLine = false

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            let fields = line
                .split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)

            if !sawFirstLine {
                sawFirstLine = true
                // A non-numeric first field means this is a header line.
                if fields.first.flatMap(Double.init) == nil {
                    guard fields.first?.lowercased() == "timestamp" else {
                        throw DecodeError.malformedRow(line: lineNumber, reason: "unrecognised header")
                    }
                    continue
                }
            }

            guard fields.count == 10 else {
                throw DecodeError.malformedRow(
                    line: lineNumber,
                    reason: "expected 10 fields, found \(fields.count)"
                )
            }

            guard let timestamp = Double(fields[0]), timestamp.isFinite else {
                throw DecodeError.malformedRow(line: lineNumber, reason: "bad timestamp")
            }
            guard let faceFound = parseFlag(fields[1]) else {
                throw DecodeError.malformedRow(line: lineNumber, reason: "bad faceFound flag")
            }
            guard let bboxX = Double(fields[2]),
                  let bboxY = Double(fields[3]),
                  let bboxW = Double(fields[4]),
                  let bboxH = Double(fields[5]),
                  [bboxX, bboxY, bboxW, bboxH].allSatisfy({ $0.isFinite }) else {
                throw DecodeError.malformedRow(line: lineNumber, reason: "bad bounding box")
            }

            let yaw = try optionalDouble(fields[6], line: lineNumber, field: "yaw")
            let roll = try optionalDouble(fields[7], line: lineNumber, field: "roll")
            let leftEye = try parseEye(fields[8], line: lineNumber, field: "leftEye")
            let rightEye = try parseEye(fields[9], line: lineNumber, field: "rightEye")

            observations.append(
                FaceObservation(
                    timestamp: timestamp,
                    faceFound: faceFound,
                    leftEye: leftEye,
                    rightEye: rightEye,
                    faceBoundingBox: CGRect(x: bboxX, y: bboxY, width: bboxW, height: bboxH),
                    yaw: yaw,
                    roll: roll
                )
            )
        }

        return observations
    }

    // MARK: - Helpers

    private static func encodeEye(_ points: [CGPoint]) -> String {
        points
            .map { "\(format(Double($0.x))) \(format(Double($0.y)))" }
            .joined(separator: " ")
    }

    private static func parseEye(
        _ field: String,
        line: Int,
        field name: String
    ) throws -> [CGPoint] {
        let parts = field
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count.isMultiple(of: 2) else {
            throw DecodeError.malformedRow(line: line, reason: "\(name) has an odd coordinate count")
        }

        var points: [CGPoint] = []
        points.reserveCapacity(parts.count / 2)
        var index = 0
        while index < parts.count {
            guard let x = Double(parts[index]),
                  let y = Double(parts[index + 1]),
                  x.isFinite,
                  y.isFinite else {
                throw DecodeError.malformedRow(line: line, reason: "\(name) has a bad coordinate")
            }
            points.append(CGPoint(x: x, y: y))
            index += 2
        }
        return points
    }

    private static func optionalDouble(
        _ field: String,
        line: Int,
        field name: String
    ) throws -> Double? {
        if field.isEmpty { return nil }
        guard let value = Double(field), value.isFinite else {
            throw DecodeError.malformedRow(line: line, reason: "bad \(name)")
        }
        return value
    }

    private static func parseFlag(_ field: String) -> Bool? {
        switch field.lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// Writes landmark rows incrementally during a debug recording session.
public final class LandmarkCSVRecorder {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "blinko.landmark-recorder")

    public init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((LandmarkCSV.header + "\n").utf8))
    }

    public func append(_ observation: FaceObservation) {
        let line = LandmarkCSV.encodeLine(observation) + "\n"
        queue.async { [handle] in
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    public func close() {
        queue.sync { [handle] in
            try? handle.close()
        }
    }
}
