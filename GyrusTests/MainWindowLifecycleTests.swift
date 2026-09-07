import AppKit
import XCTest
@testable import Gyrus

@MainActor
final class MainWindowLifecycleTests: XCTestCase {
    private func window(_ title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    func testDockReopenBeforeAnyWindowUsesInstalledSceneOpener() {
        let delegate = GyrusApplicationDelegate()
        var opens = 0
        delegate.installMainWindowOpener { opens += 1 }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertEqual(opens, 1)
        XCTAssertNil(delegate.mainWindow)
    }

    func testEarlyDockEventIsNotSwallowedAndReplayedWhenOpenerArrives() async {
        let delegate = GyrusApplicationDelegate()
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        let opened = expectation(description: "Pending login activation opens main scene")
        delegate.installMainWindowOpener { opened.fulfill() }
        await fulfillment(of: [opened], timeout: 2)
    }

    func testSettingsBeingVisibleDoesNotReplaceTheLibrary() {
        let delegate = GyrusApplicationDelegate()
        let settings = window("Settings")
        defer { settings.close() }
        settings.makeKeyAndOrderFront(nil)
        var opens = 0
        delegate.installMainWindowOpener { opens += 1 }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(opens, 1)
        XCTAssertNil(delegate.mainWindow)
        XCTAssertNotEqual(settings.identifier?.rawValue, "gyrus-main-window")
    }

    func testAttachmentRegistersItsOwnWindowWhenSettingsIsKey() async {
        let delegate = GyrusApplicationDelegate()
        let library = window("Gyrus")
        let settings = window("Settings")
        defer { library.orderOut(nil); settings.close() }
        let attachment = MainWindowAttachmentView()
        let attached = expectation(description: "Main scene attachment")
        attachment.didAttach = { actual in
            delegate.registerMainWindow(actual)
            attached.fulfill()
        }
        library.contentView = attachment
        settings.makeKeyAndOrderFront(nil)
        await fulfillment(of: [attached], timeout: 2)
        XCTAssertTrue(delegate.mainWindow === library)
        XCTAssertNotEqual(settings.identifier?.rawValue, "gyrus-main-window")
    }

    func testCloseThenDockReopenShowsSameLibraryWindow() {
        let delegate = GyrusApplicationDelegate()
        let library = window("Gyrus")
        defer { library.orderOut(nil) }
        delegate.registerMainWindow(library)
        library.makeKeyAndOrderFront(nil)
        library.performClose(nil)
        XCTAssertFalse(library.isVisible)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(library.isVisible)
        XCTAssertTrue(delegate.mainWindow === library)
    }

    func testActivationRestoresHiddenLibraryWithoutOpeningAnotherScene() {
        let delegate = GyrusApplicationDelegate()
        let library = window("Gyrus")
        defer { library.orderOut(nil) }
        delegate.registerMainWindow(library)
        delegate.installMainWindowOpener { XCTFail("Must reuse existing library") }
        library.orderOut(nil)
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertTrue(library.isVisible)
    }
}
