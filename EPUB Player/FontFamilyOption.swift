//
//  FontFamilyOption.swift
//  Immersive Reader
//
//  Created by OpenCode on 30/4/2026.
//

import ReadiumNavigator

nonisolated struct FontFamilyOption: Identifiable, Hashable {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let value: FontFamily?

    nonisolated init(name: String, value: FontFamily?) {
        self.id = value?.rawValue ?? ""
        self.name = name
        self.value = value
    }
}
