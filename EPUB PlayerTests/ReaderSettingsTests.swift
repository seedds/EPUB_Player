//
//  ReaderSettingsTests.swift
//  EPUB PlayerTests
//

import SwiftUI
import XCTest
@testable import EPUBPlayer

final class ReaderSettingsTests: XCTestCase {
    // MARK: - defaultBackground(forTheme:colorScheme:) (#14)

    func testSystemThemeUsesSchemeForBackground() {
        // The System theme must derive its background from the (device) color
        // scheme it is given — dark device -> black, light device -> white.
        XCTAssertEqual(
            ReaderSettings.defaultBackground(forTheme: .system, colorScheme: .dark),
            .black,
            "System theme on a dark device must default to a black reading background"
        )
        XCTAssertEqual(
            ReaderSettings.defaultBackground(forTheme: .system, colorScheme: .light),
            .white
        )
    }

    func testLightThemeAlwaysWhiteRegardlessOfScheme() {
        XCTAssertEqual(ReaderSettings.defaultBackground(forTheme: .light, colorScheme: .dark), .white)
        XCTAssertEqual(ReaderSettings.defaultBackground(forTheme: .light, colorScheme: .light), .white)
    }

    func testDarkThemeAlwaysBlackRegardlessOfScheme() {
        XCTAssertEqual(ReaderSettings.defaultBackground(forTheme: .dark, colorScheme: .dark), .black)
        XCTAssertEqual(ReaderSettings.defaultBackground(forTheme: .dark, colorScheme: .light), .black)
    }
}
