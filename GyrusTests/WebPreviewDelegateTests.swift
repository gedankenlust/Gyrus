import XCTest
import WebKit
@testable import Gyrus

/// WebKit looks optional delegate methods up by selector. A signature that only
/// nearly matches the protocol (for example a decision handler without the
/// `@MainActor @Sendable` attributes) compiles, but WebKit never calls it, and
/// the preview would then load private-network addresses it is meant to block.
@MainActor
final class WebPreviewDelegateTests: XCTestCase {
    private let navigationPolicySelector = NSSelectorFromString(
        "webView:decidePolicyForNavigationAction:decisionHandler:"
    )

    func testPagePreviewCoordinatorExposesNavigationPolicy() {
        let coordinator = WebPreviewView.Coordinator(WebController(), initialURL: URL(string: "https://example.com")!)
        XCTAssertTrue(coordinator.responds(to: navigationPolicySelector))
    }

    func testLiveViewportCoordinatorExposesNavigationPolicy() {
        let coordinator = LiveViewportWebView.Coordinator(url: URL(string: "https://example.com")!)
        XCTAssertTrue(coordinator.responds(to: navigationPolicySelector))
    }
}
