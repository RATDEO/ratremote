import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import RatRemote

final class SystemShortcutEventSequenceTests: XCTestCase {
    func testExternalControlUpScript() {
        XCTAssertEqual(
            SystemShortcutEventSequence.appleScriptSource(
                keyCode: CGKeyCode(kVK_UpArrow),
                flags: .maskControl
            ),
            #"tell application "System Events" to key code 126 using control down"#
        )
    }

    func testControlUpSequenceExplicitlyReleasesControl() {
        let events = SystemShortcutEventSequence.make(
            keyCode: CGKeyCode(kVK_UpArrow),
            flags: .maskControl
        )

        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], SystemShortcutKeyEvent(
            keyCode: CGKeyCode(kVK_Control),
            isKeyDown: true,
            flags: .maskControl
        ))
        XCTAssertEqual(events[1].keyCode, CGKeyCode(kVK_UpArrow))
        XCTAssertTrue(events[1].isKeyDown)
        XCTAssertEqual(events[1].flags, .maskControl)
        XCTAssertEqual(events[2].keyCode, CGKeyCode(kVK_UpArrow))
        XCTAssertFalse(events[2].isKeyDown)
        XCTAssertEqual(events[2].flags, .maskControl)
        XCTAssertEqual(events[3], SystemShortcutKeyEvent(
            keyCode: CGKeyCode(kVK_Control),
            isKeyDown: false,
            flags: []
        ))
    }

    func testMultipleModifiersReleaseInReverseOrder() {
        let flags: CGEventFlags = [.maskControl, .maskShift]
        let events = SystemShortcutEventSequence.make(
            keyCode: CGKeyCode(kVK_LeftArrow),
            flags: flags
        )

        XCTAssertEqual(events.map(\.keyCode), [
            CGKeyCode(kVK_Control),
            CGKeyCode(kVK_Shift),
            CGKeyCode(kVK_LeftArrow),
            CGKeyCode(kVK_LeftArrow),
            CGKeyCode(kVK_Shift),
            CGKeyCode(kVK_Control)
        ])
        XCTAssertEqual(events.last?.flags, [])
        XCTAssertFalse(events.last?.isKeyDown ?? true)
    }
}
