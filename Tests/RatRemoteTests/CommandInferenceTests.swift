import XCTest
@testable import RatRemote

final class CommandInferenceTests: XCTestCase {
    func testValidatorAcceptsSimpleKeyboardCommand() throws {
        let action = RemoteAction(
            type: .keyPress,
            text: nil,
            key: "p",
            modifiers: ["command", "shift"],
            url: nil,
            x: nil,
            y: nil,
            amount: nil
        )

        let result = try CommandActionValidator.validate(CommandResponse(actions: [action]))
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertEqual(result.actions[0].key, "p")
    }

    func testValidatorRepairsAppleKeyPressTextField() throws {
        let action = RemoteAction(
            type: .keyPress,
            text: "enter",
            key: nil,
            modifiers: nil,
            url: nil,
            x: nil,
            y: nil,
            amount: nil
        )

        let result = try CommandActionValidator.validate(CommandResponse(actions: [action]))
        XCTAssertEqual(result.actions[0].key, "return")
        XCTAssertNil(result.actions[0].text)
    }

    func testClickEnterIsHandledWithoutACommandModel() {
        let actions = LocalCommandParser.actions(for: "Click Enter")
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].type, .keyPress)
        XCTAssertEqual(actions[0].key, "return")
    }

    func testValidatorRejectsAppleScriptFromOnDeviceModel() {
        let action = RemoteAction(
            type: .runAppleScript,
            text: "tell application \"Finder\" to empty trash",
            key: nil,
            modifiers: nil,
            url: nil,
            x: nil,
            y: nil,
            amount: nil
        )

        XCTAssertThrowsError(try CommandActionValidator.validate(CommandResponse(actions: [action])))
    }

    func testValidatorRejectsNonWebURL() {
        let action = RemoteAction(
            type: .openURL,
            text: nil,
            key: nil,
            modifiers: nil,
            url: "file:///tmp/private.txt",
            x: nil,
            y: nil,
            amount: nil
        )

        XCTAssertThrowsError(try CommandActionValidator.validate(CommandResponse(actions: [action])))
    }

    func testValidatorRejectsMissingApplicationName() {
        let action = RemoteAction(
            type: .openApplication,
            text: nil,
            key: nil,
            modifiers: nil,
            url: nil,
            x: nil,
            y: nil,
            amount: nil
        )

        XCTAssertThrowsError(try CommandActionValidator.validate(CommandResponse(actions: [action])))
    }

    func testCommandProviderSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.commandModelProvider = .localGemma
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(decoded.commandModelProvider, .localGemma)
    }
}
