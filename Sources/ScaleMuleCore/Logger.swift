import Foundation
import os.log

public final class SMLogger: Sendable {
    private let logger: os.Logger
    private let isDebug: Bool

    public init(subsystem: String = "com.scalemule.sdk", category: String = "default", debug: Bool = false) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
        self.isDebug = debug
    }

    public func debug(_ message: String) {
        guard isDebug else { return }
        logger.debug("\(message, privacy: .public)")
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
