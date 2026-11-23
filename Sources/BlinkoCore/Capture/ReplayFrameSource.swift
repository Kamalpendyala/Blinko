import Foundation

/// Plays back a recorded landmark CSV as if it were a live face stream.
///
/// With `pace: false` all frames are emitted synchronously from `start()`,
/// which is what tests use. With `pace: true` frames are scheduled relative
/// to the recording's own timestamps so the debug window animates.
public final class ReplayFrameSource: LandmarkFrameSource {
    public enum ReplayError: Error, Equatable, CustomStringConvertible {
        case empty

        public var description: String {
            switch self {
            case .empty:
                return "The replay file contains no frames."
            }
        }
    }

    public let observations: [FaceObservation]
    public var onFrame: ((FaceObservation) -> Void)?
    public var onFinish: (() -> Void)?
    public private(set) var isRunning = false

    private let pace: Bool
    private let queue = DispatchQueue(label: "blinko.replay")
    private var generation = 0

    public init(observations: [FaceObservation], pace: Bool = false) {
        self.observations = observations
        self.pace = pace
    }

    public convenience init(csv: String, pace: Bool = false) throws {
        try self.init(observations: LandmarkCSV.decode(csv), pace: pace)
    }

    public convenience init(contentsOf url: URL, pace: Bool = false) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try self.init(csv: text, pace: pace)
    }

    public func start() throws {
        guard !observations.isEmpty else { throw ReplayError.empty }
        guard !isRunning else { return }

        isRunning = true
        generation += 1
        let token = generation

        guard pace else {
            for observation in observations {
                onFrame?(observation)
            }
            isRunning = false
            // Let queued UI work drain before announcing completion.
            DispatchQueue.main.async { [weak self] in
                self?.onFinish?()
            }
            return
        }

        let base = observations[0].timestamp
        for observation in observations {
            let delay = max(0, observation.timestamp - base)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning, self.generation == token else { return }
                self.onFrame?(observation)
            }
        }

        if let last = observations.last {
            let finishDelay = max(0, last.timestamp - base) + 0.05
            queue.asyncAfter(deadline: .now() + finishDelay) { [weak self] in
                guard let self, self.isRunning, self.generation == token else { return }
                self.isRunning = false
                self.onFinish?()
            }
        }
    }

    public func stop() {
        isRunning = false
        generation += 1
    }
}
