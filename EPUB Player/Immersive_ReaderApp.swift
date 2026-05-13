//
//  Immersive_ReaderApp.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct Immersive_ReaderApp: App {
    @StateObject private var appStateStore = AppStateStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if canImport(UIKit)
        let font = UIFont.preferredFont(forTextStyle: .title3)

        UISegmentedControl.appearance().setTitleTextAttributes(
            [.font: font],
            for: .normal
        )
        UISegmentedControl.appearance().setTitleTextAttributes(
            [.font: font],
            for: .selected
        )
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appStateStore)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                appStateStore.persistNow()
            }
        }
    }
}
