import XCTest
import DoongdoongAI
@testable import DoongdoongCodex

final class DurationEstimateTests: XCTestCase {
    @MainActor func testEveryConfigurationSuppliesUsableEstimatesWithoutCLI() {
        // Estimation must work before login/discovery, including manually named models.
        let models = CodexModel.allCases + [CodexModel(rawValue: "future-model")!]
        for model in models {
            for effort in ReasoningEffort.allCases {
                let provider: any TextGenerationProvider = CodexTextProvider(configuration: .init(
                    executable: URL(fileURLWithPath: "/no-codex-installed"), model: model, reasoningEffort: effort))
                for task in TextGenerationWorkload.Task.allCases {
                    var previous: TimeInterval = 0
                    for count in [Int.min, -1, 0, 1, 13_801, 100_000, Int.max] {
                        let duration = provider.estimatedDuration(for: .init(task: task, characterCount: count))
                        XCTAssertTrue(duration.isFinite, "\(model.rawValue)/\(effort)/\(task)/\(count)")
                        XCTAssertGreaterThan(duration, 0)
                        XCTAssertGreaterThanOrEqual(duration, previous)
                        XCTAssertLessThanOrEqual(duration, 3600)
                        previous = duration
                    }
                }
            }
        }
    }

    @MainActor func testCorrectionEstimateRetainsExistingProductTiming() {
        let provider: any TextGenerationProvider = CodexTextProvider(configuration: .init(
            executable: URL(fileURLWithPath: "/no-codex-installed")))
        XCTAssertEqual(provider.estimatedDuration(for: .init(task: .correction, characterCount: 13_801)), 225.612, accuracy: 0.001)
        XCTAssertEqual(provider.estimatedDuration(for: .init(task: .correction, characterCount: 0)), 120)
        XCTAssertEqual(provider.estimatedDuration(for: .init(task: .summary, characterCount: 0)), 60)
    }
}
