import Foundation
import XCTest

/// Real-app proof for openclaw/openclaw#193817: composer text and attachments
/// edited while sessions.rewind is in flight must survive its delayed completion.
/// Runs the real app in a task-owned simulator against the owned loopback fixture
/// Gateway (scripts/test-ios-shell-gateway.mjs --rewind); no live credentials.
/// The pre-fix tree fails this exact test with REWIND_PROOF_COMPOSER_LOST.
///
/// Flow note: the app abandons any mutation RPC after 15000ms
/// (ChatGatewayRequest.swift mutationTimeoutMs), so the held window stays well
/// under that: the photo is staged BEFORE the rewind starts, only the short
/// text edit happens while the response is held, and the fixture reports the
/// measured hold so the test fails loudly if the window ever nears the timeout.
/// The Branches control check at the end is diagnostic-only: branch listing is
/// not the behavior corrected by #193867, so a missing menu is captured as a
/// screenshot and a log line, never asserted.
@MainActor
final class RewindComposerUITests: XCTestCase {
    override func setUpWithError() throws {
        // Keep going after the expected pre-fix failures so the baseline tree
        // records every REWIND_PROOF marker plus the post-release screenshots.
        continueAfterFailure = true
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

        // Stage the photo attachment BEFORE the rewind begins. The iOS 27 system
        // picker can take 60s+ to label thumbnails on a fresh simulator, far
        // beyond the app's 15000ms mutation timeout, so it cannot run while the
        // rewind response is held.
        let picker = app.buttons["chat-attachment-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let library = app.buttons["Photo Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5), app.debugDescription)
        library.tap()
        // System-owned picker selectors validated on iOS 27 by PhotoAttachmentLockUITests.
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        // Picker thumbnails get their "Photo, ..." labels only after the picker
        // finishes loading: observed 30+s on a freshly booted simulator.
        if !photo.waitForExistence(timeout: 60) {
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
        XCTAssertTrue(photo.waitForExistence(timeout: 30), "SETUP: synthetic system picker photo")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.navigationBars["Photos"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "SETUP: system picker Done")
        XCTAssertTrue(done.isEnabled)
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let chip = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "photo-")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "SETUP: staged photo attachment")
        self.capture(app, named: "photo-staged-before-rewind")

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

        // The only edit inside the held window: a few seconds of typing, safely
        // inside the app's 15000ms mutation timeout.
        input.tap()
        let draft = "Keep this newer note"
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        self.capture(app, named: "newer-draft-during-pending-rewind")

        // Release the held completion immediately. The fixture still reports the
        // rewound prompt/attachments, then serves truncated history and a
        // refreshed branch list.
        let released = try await self.rewindRequest(fixtureURL, path: "release", method: "POST")
        XCTAssertTrue(released.released)

        // The history refresh lands in both trees; the composer value then differs.
        XCTAssertTrue(
            rewoundBubble.waitForNonExistence(timeout: 20),
            "History refresh must remove the rewound message")
        XCTAssertTrue(setupBubble.exists, "History refresh keeps earlier messages")
        let state = try await self.rewindRequest(fixtureURL, path: "state")
        self.capture(app, named: "composer-after-release")

        // Harness health: the rewind response must have been delivered well
        // inside the app's 15000ms mutation timeout, or neither tree exercises
        // the code path the fix changes.
        if let requestedAt = state.requestedAtMs, let completedAt = state.completedAtMs {
            XCTAssertLessThan(
                completedAt - requestedAt,
                12000,
                "HARNESS_TIMEOUT_RISK: app mutation timeout is 15000ms; measured hold was \(completedAt - requestedAt)ms")
        } else {
            XCTFail("HARNESS_TIMEOUT_RISK: fixture did not report rewind request/completion timestamps")
        }
        XCTAssertTrue(
            state.wire.contains { $0.method == "sessions.rewind" && $0.phase == "completed" },
            "HARNESS_REWIND_RESPONSE_MISSING: fixture never delivered the rewind response")

        // Core before/after: the pre-fix tree restores the rewound prompt and
        // drops the staged photo; the fixed tree keeps both.
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

        // Diagnostic only (not the behavior corrected by #193867): the refreshed
        // branch list should surface in the composer controls. Never asserted.
        let branches = app.buttons["Branches"]
        if branches.waitForExistence(timeout: 10) {
            branches.tap()
            let priorBranch = app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@", "4 messages")).firstMatch
            if priorBranch.waitForExistence(timeout: 5) {
                self.capture(app, named: "branches-after-rewind")
            } else {
                NSLog("BRANCH DIAGNOSTIC: Branches menu opened but the rewound-away branch row is missing")
                self.capture(app, named: "branches-menu-missing-row")
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        } else {
            NSLog("BRANCH DIAGNOSTIC: Branches control absent after rewind refresh")
            self.capture(app, named: "branches-menu-missing")
        }
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
        let requestedAtMs: Int?
        let completedAtMs: Int?
        let wire: [RewindWireEntry]
    }
}
