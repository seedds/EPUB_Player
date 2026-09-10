//
//  FontFamilyOption.swift
//  EPUB Player
//
//  Created by OpenCode on 30/4/2026.
//

import ReadiumNavigator

nonisolated struct FontFamilyOption: Identifiable, Hashable {
    let id: String
    let name: String
    let value: FontFamily?

    init(name: String, value: FontFamily?) {
        self.id = value?.rawValue ?? ""
        self.name = name
        self.value = value
    }
}
