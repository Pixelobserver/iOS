import PromiseKit
@testable import Shared
import XCTest

final class HAAPIPersistentEventTests: XCTestCase {
    private var previousWebhookManager: WebhookManager!
    private var webhookManager: FakeWebhookManager!

    override func setUp() {
        super.setUp()
        previousWebhookManager = Current.webhooks
        webhookManager = FakeWebhookManager()
        Current.webhooks = webhookManager
    }

    override func tearDown() {
        Current.webhooks = previousWebhookManager
        webhookManager = nil
        previousWebhookManager = nil
        super.tearDown()
    }

    func testPersistentEventUsesBackgroundSessionDirectly() {
        let sent = expectation(description: "event sent")
        webhookManager.sendRequestHandler = { _, _, request, seal in
            let payload = request.data as? [String: Any]
            XCTAssertEqual(payload?["event_type"] as? String, "ios.zone_entered")
            seal.fulfill(())
            sent.fulfill()
        }
        let api = HomeAssistantAPI(server: .fake())

        api.CreatePersistentEvent(
            eventType: "ios.zone_entered",
            eventData: ["zone": "zone.postfach"]
        ).cauterize()

        wait(for: [sent], timeout: 1)
        XCTAssertEqual(webhookManager.sendPersistedBackgroundCount, 1)
        XCTAssertEqual(webhookManager.sendCount, 0)
    }
}
