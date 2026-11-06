import Foundation
import XCTest

/// Real-app proof for openclaw/openclaw#193817: composer text and attachments
/// edited while sessions.rewind is in flight must survive its delayed completion.
/// Runs the real app in a task-owned simulator against the owned loopback fixture
/// Gateway (scripts/test-ios-shell-gateway.mjs --rewind); no live credentials.
/// The pre-fix tree fails this exact test with REWIND_PROOF_COMPOSER_LOST.
@MainActor
final class RewindComposerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNewerComposerSurvivesDelayedRewind() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["OPENCLAW_IOS_REWIND_PROOF"] == "1",
            "Requires the isolated shell Gateway with --rewind")
        let setupCode = try XCTUnwrap(environment["OPENCLAW_IOS_LIVE_SETUP_CODE"])
        let fixtureURL = try XCTUnwrap(
            environment["OPENCLAW_IOS_REWIND_FIXTURE_URL"].flatMap(URL.init(string:)))
        guard fixtureURL.scheme == "http", fixtureURL.host == "127.0.0.1" else {
            XCTFail("Rewind proof requires the owned loopback fixture")
            return
        }

        let app = XCUIApplication()
        defer { app.terminate() }
        self.launchChatApp(app, setupCode: setupCode)

        let input = app.descendants(matching: .any)["chat-message-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 30), app.debugDescription)

        let rewoundBubble = app.staticTexts["Earlier prompt"]
        XCTAssertTrue(rewoundBubble.waitForExistence(timeout: 15), app.debugDescription)
        let setupBubble = app.staticTexts["Setup context for the Rewind proof."]
        XCTAssertTrue(setupBubble.waitForExistence(timeout: 5), app.debugDescription)
        self.capture(app, named: "history-before-rewind")

        // Trigger Rewind on the seeded user message; the fixture holds the response.
        rewoundBubble.press(forDuration: 1)
        let rewindAction = app.buttons["Rewind to Here"]
        XCTAssertTrue(rewindAction.waitForExistence(timeout: 5), app.debugDescription)
        self.capture(app, named: "rewind-affordance")
        rewindAction.tap()

        let held = try await self.rewindRequest(fixtureURL, path: "await-request", timeout: 30)
        XCTAssertTrue(held.requested, "The real app must send sessions.rewind")
        XCTAssertTrue(held.held, "The fixture must hold the rewind response")
        self.capture(app, named: "rewind-pending")

        // While the completion is in flight, edit the composer: newer text plus a
        // staged photo attachment.
        input.tap()
        let draft = "Keep this newer note"
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        let picker = app.buttons["chat-attachment-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let library = app.buttons["Photo Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5), app.debugDescription)
        library.tap()
        // System-owned picker selectors validated on iOS 27 by PhotoAttachmentLockUITests.
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        if !photo.waitForExistence(timeout: 20) {
            NSLog(
                "PICKER DIAGNOSTICS images=%d cells=%d buttons=%@ texts=%@",
                app.images.count, app.cells.count,
                app.buttons.allElementsBoundByIndex.prefix(10).map(\.label).description,
                app.staticTexts.allElementsBoundByIndex.prefix(15).map(\.label).description)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            self.capture(app, named: "picker-diagnostics")
        }
        XCTAssertTrue(photo.waitForExistence(timeout: 2), "SETUP: synthetic system picker photo")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.navigationBars["Photos"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "SETUP: system picker Done")
        XCTAssertTrue(done.isEnabled)
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let chip = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "photo-")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "SETUP: staged photo attachment")
        XCTAssertEqual(input.value as? String, draft)
        self.capture(app, named: "newer-draft-during-pending-rewind")

        // Release the held completion. The fixture still reports the rewound
        // prompt/attachments, then serves truncated history and refreshed branches.
        let released = try await self.rewindRequest(fixtureURL, path: "release", method: "POST")
        XCTAssertTrue(released.released)

        // The history refresh lands in both trees; the composer value then differs.
        XCTAssertTrue(
            rewoundBubble.waitForNonExistence(timeout: 20),
            "History refresh must remove the rewound message")
        XCTAssertTrue(setupBubble.exists, "History refresh keeps earlier messages")
        let state = try await self.rewindRequest(fixtureURL, path: "state")
        self.capture(app, named: "composer-after-release")

        XCTAssertEqual(
            input.value as? String,
            draft,
            "REWIND_PROOF_COMPOSER_LOST: delayed rewind overwrote newer composer text")
        XCTAssertTrue(
            chip.exists,
            "REWIND_PROOF_ATTACHMENT_LOST: delayed rewind dropped a newer attachment")
        XCTAssertTrue(
            state.wire.contains { $0.method == "chat.history" && $0.phase == "after-release" },
            "REWIND_PROOF_HISTORY_REFRESH_MISSING")
        XCTAssertTrue(
            state.wire.contains { $0.method == "sessions.branches.list" && $0.phase == "after-release" },
            "REWIND_PROOF_BRANCH_REFRESH_MISSING")

        // The refreshed branch list is visible in the real composer controls.
        let branches = app.buttons["Branches"]
        XCTAssertTrue(branches.waitForExistence(timeout: 5), app.debugDescription)
        branches.tap()
        let priorBranch = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "4 messages")).firstMatch
        XCTAssertTrue(
            priorBranch.waitForExistence(timeout: 5),
            "Branch refresh must list the rewound-away branch")
        self.capture(app, named: "branches-after-rewind")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
    }

    private func launchChatApp(_ app: XCUIApplication, setupCode: String) {
        addUIInterruptionMonitor(withDescription: "Local network access") { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }
        app.launchArguments = [
            "--openclaw-reset-onboarding", "--openclaw-initial-tab", "chat",
            "--openclaw-initial-destination", "chat", "-AppleLanguages", "(en)",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 15))
        app.buttons["Continue"].tap()
        app.tap()
        XCTAssertTrue(app.buttons["Connect Manually"].waitForExistence(timeout: 10))
        app.buttons["Connect Manually"].tap()
        let setupField = app.textFields["Enter setup code"]
        XCTAssertTrue(setupField.waitForExistence(timeout: 5))
        setupField.tap()
        setupField.typeText(setupCode)
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.staticTexts["You're connected"].waitForExistence(timeout: 60))
        app.buttons["Go to Chat"].tap()
    }

    private func rewindRequest(
        _ baseURL: URL,
        path: String,
        method: String = "GET",
        timeout: TimeInterval = 5) async throws -> RewindState
    {
        let url = baseURL.appendingPathComponent("rewind").appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "rewind-wire-\(path)"
        evidence.lifetime = .keepAlways
        self.add(evidence)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(RewindState.self, from: data)
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        self.add(screenshot)
    }

    private struct RewindWireEntry: Decodable {
        let method: String
        let phase: String
    }

    private struct RewindState: Decodable {
        let requested: Bool
        let held: Bool
        let released: Bool
        let wire: [RewindWireEntry]
    }
}
