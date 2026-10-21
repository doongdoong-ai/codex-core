import Foundation

/// Only capacity failures should trigger a retry with smaller input.
public enum TextGenerationError: Error, Equatable, Sendable {
    case capacityExceeded
}
