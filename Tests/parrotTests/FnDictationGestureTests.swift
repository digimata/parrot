import XCTest
@testable import parrot

final class FnDictationGestureTests: XCTestCase {
    func testLongPressKeepsPushToTalkBehavior() {
        var gesture = FnDictationGesture()

        XCTAssertEqual(gesture.handle(.pressed(at: 1.0)), [.startRecording])
        XCTAssertEqual(gesture.handle(.released(at: 2.0)), [.stopRecording])
        XCTAssertFalse(gesture.isLocked)
    }

    func testSingleQuickTapStopsAfterDoubleTapWindowExpires() {
        var gesture = FnDictationGesture(doubleTapInterval: 0.4)

        XCTAssertEqual(gesture.handle(.pressed(at: 1.0)), [.startRecording])
        XCTAssertEqual(
            gesture.handle(.released(at: 1.1)),
            [.scheduleSecondTapTimeout(after: 0.4)]
        )
        XCTAssertEqual(gesture.handle(.secondTapTimedOut), [.stopRecording])
        XCTAssertFalse(gesture.isLocked)
    }

    func testDoubleTapLocksThenNextPressStops() {
        var gesture = FnDictationGesture(doubleTapInterval: 0.4)

        XCTAssertEqual(gesture.handle(.pressed(at: 1.0)), [.startRecording])
        _ = gesture.handle(.released(at: 1.1))
        XCTAssertEqual(
            gesture.handle(.pressed(at: 1.2)),
            [.cancelSecondTapTimeout]
        )
        XCTAssertFalse(gesture.isLocked)
        XCTAssertEqual(gesture.handle(.released(at: 1.25)), [.showLocked])
        XCTAssertTrue(gesture.isLocked)
        XCTAssertEqual(gesture.handle(.secondTapTimedOut), [])
        XCTAssertEqual(gesture.handle(.pressed(at: 3.0)), [])
        XCTAssertTrue(gesture.isLocked)
        XCTAssertEqual(gesture.handle(.released(at: 3.1)), [.stopRecording])
        XCTAssertFalse(gesture.isLocked)
    }

    func testLongSecondPressFinishesInsteadOfLocking() {
        var gesture = FnDictationGesture()

        _ = gesture.handle(.pressed(at: 1.0))
        _ = gesture.handle(.released(at: 1.1))
        XCTAssertEqual(gesture.handle(.pressed(at: 1.2)), [.cancelSecondTapTimeout])
        XCTAssertEqual(gesture.handle(.released(at: 2.0)), [.stopRecording])
        XCTAssertFalse(gesture.isLocked)
    }

    func testDuplicateEdgesDoNotStartOrStopTwice() {
        var gesture = FnDictationGesture()

        XCTAssertEqual(gesture.handle(.pressed(at: 1.0)), [.startRecording])
        XCTAssertEqual(gesture.handle(.pressed(at: 1.1)), [])
        XCTAssertEqual(gesture.handle(.released(at: 2.0)), [.stopRecording])
        XCTAssertEqual(gesture.handle(.released(at: 2.1)), [])
    }
}
