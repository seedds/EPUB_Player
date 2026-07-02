//
//  WeakScriptMessageHandlerTests.swift
//  EPUB PlayerTests
//

import WebKit
import XCTest
@testable import EPUBPlayer

@MainActor
final class WeakScriptMessageHandlerTests: XCTestCase {
    /// A stand-in for the reader Coordinator: an object that would be leaked if
    /// a `WKUserContentController` retained it strongly.
    private final class SpyHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    func testProxyDoesNotRetainTarget() {
        var target: SpyHandler? = SpyHandler()
        weak var weakTarget = target
        let proxy = WeakScriptMessageHandler(target: target!)

        target = nil

        XCTAssertNil(weakTarget, "Proxy must hold its target weakly")
        XCTAssertNil(proxy.target, "Proxy's target reference must clear once the target deallocates")
    }

    /// Reproduces the finding's scenario: several `WKUserContentController`s (as
    /// Readium creates one per spread) all register the handler. With the weak
    /// proxy, none of them keep the target alive, so the target deallocates once
    /// the owner drops it — even though the controllers still hold the proxy.
    func testMultipleUserContentControllersDoNotRetainTarget() {
        var target: SpyHandler? = SpyHandler()
        weak var weakTarget = target

        // Retain the controllers for the duration of the test to prove it is
        // specifically the *proxy* registration (not controller lifetime) that
        // avoids retaining the target.
        var controllers: [WKUserContentController] = []
        for _ in 0..<3 {
            let ucc = WKUserContentController()
            ucc.add(WeakScriptMessageHandler(target: target!), name: "mediaOverlayAudioTap")
            controllers.append(ucc)
        }

        target = nil

        XCTAssertNil(weakTarget, "No WKUserContentController may keep the target alive via the weak proxy")
        XCTAssertEqual(controllers.count, 3, "Controllers stay alive; only the strong target retention is broken")
    }
}
