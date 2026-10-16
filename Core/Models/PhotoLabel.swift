//
//  PhotoLabel.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Aperture's seven colour labels. Stored as a small integer on the photo
//  row (0 = none) so sorting and filtering stay cheap, and so an Aperture
//  library's labels land one-to-one.
//

import SwiftUI

enum PhotoLabel: Int, CaseIterable, Identifiable, Codable {
    case none = 0
    case red, orange, yellow, green, blue, purple, gray

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .none: return "No Label"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .gray: return "Gray"
        }
    }

    var color: Color {
        switch self {
        case .none: return .clear
        case .red: return Color(red: 0.93, green: 0.27, blue: 0.25)
        case .orange: return Color(red: 0.96, green: 0.58, blue: 0.16)
        case .yellow: return Color(red: 0.95, green: 0.80, blue: 0.20)
        case .green: return Color(red: 0.38, green: 0.76, blue: 0.36)
        case .blue: return Color(red: 0.27, green: 0.55, blue: 0.93)
        case .purple: return Color(red: 0.62, green: 0.42, blue: 0.88)
        case .gray: return Color(white: 0.58)
        }
    }

    /// The seven real colours, for pickers (no "none" swatch).
    static let colors: [PhotoLabel] = allCases.filter { $0 != .none }
}
