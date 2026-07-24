import XCTest
@testable import GrootKit

/// The safety model's test suite. Every cell of the truth table is asserted
/// explicitly — this is the one place the "destructive always prompts" rule is
/// enforced, so it gets exhaustive coverage rather than spot checks.
final class ApprovalPolicyTests: XCTestCase {

    // MARK: The full truth table (6 cells)

    func testReversibleInPreviewProposes() {
        XCTAssertEqual(ApprovalPolicy.decide(isDestructive: false, autonomy: .preview), .propose)
    }

    func testReversibleInApprovalAsksUser() {
        XCTAssertEqual(ApprovalPolicy.decide(isDestructive: false, autonomy: .approval), .askUser)
    }

    func testReversibleInAutopilotProceeds() {
        XCTAssertEqual(ApprovalPolicy.decide(isDestructive: false, autonomy: .autopilot), .proceed)
    }

    func testDestructiveInPreviewProposes() {
        XCTAssertEqual(ApprovalPolicy.decide(isDestructive: true, autonomy: .preview), .propose)
    }

    func testDestructiveInApprovalAsksUser() {
        XCTAssertEqual(ApprovalPolicy.decide(isDestructive: true, autonomy: .approval), .askUser)
    }

    /// **The invariant.** Autopilot must never carry out destructive work
    /// unattended, no matter what mode the user selected.
    func testDestructiveInAutopilotStillAsksUser() {
        XCTAssertEqual(ApprovalPolicy.decide(isDestructive: true, autonomy: .autopilot), .askUser)
    }

    // MARK: Properties that must hold for every mode

    /// No mode may ever return `.proceed` for destructive work — stated as a
    /// property so a future mode added to `AutonomyMode` can't quietly break it.
    func testNoAutonomyModeEverProceedsOnDestructiveWork() {
        for mode in AutonomyMode.allCases {
            XCTAssertNotEqual(
                ApprovalPolicy.decide(isDestructive: true, autonomy: mode), .proceed,
                "\(mode) allowed destructive work without asking")
        }
    }

    /// Preview must never authorize a filesystem mutation in any circumstance.
    func testPreviewNeverActs() {
        for destructive in [true, false] {
            XCTAssertEqual(
                ApprovalPolicy.decide(isDestructive: destructive, autonomy: .preview), .propose)
        }
    }

    // MARK: Kind-based overload agrees with the classification

    func testKindOverloadMatchesOperationClassification() {
        for mode in AutonomyMode.allCases {
            for kind in [FileOperationKind.move, .rename, .trash] {
                XCTAssertEqual(
                    ApprovalPolicy.decide(kind: kind, autonomy: mode),
                    ApprovalPolicy.decide(isDestructive: kind.isDestructive, autonomy: mode),
                    "\(kind)/\(mode) disagreed with its destructive classification")
            }
        }
    }

    /// Trash is the destructive kind; move/rename are not. If this ever flips,
    /// the invariant above silently stops protecting anything.
    func testTrashIsTheDestructiveKind() {
        XCTAssertTrue(FileOperationKind.trash.isDestructive)
        XCTAssertFalse(FileOperationKind.move.isDestructive)
        XCTAssertFalse(FileOperationKind.rename.isDestructive)
        XCTAssertEqual(ApprovalPolicy.decide(kind: .trash, autonomy: .autopilot), .askUser)
        XCTAssertEqual(ApprovalPolicy.decide(kind: .move, autonomy: .autopilot), .proceed)
    }
}
