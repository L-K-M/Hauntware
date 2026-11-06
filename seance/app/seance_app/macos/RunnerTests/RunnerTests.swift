import Cocoa
import FlutterMacOS
import XCTest
@testable import Seance

class RunnerTests: XCTestCase {

  func testEditMenuRoutesOnlyFromFocusedKeyTerminalWindow() {
    XCTAssertEqual(
      EditMenuRouting.destination(terminalFocused: true, windowIsKey: true),
      .terminal)
    XCTAssertEqual(
      EditMenuRouting.destination(terminalFocused: false, windowIsKey: true),
      .responderChain)
    XCTAssertEqual(
      EditMenuRouting.destination(terminalFocused: true, windowIsKey: false),
      .responderChain)
  }

}
