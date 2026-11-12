//
//  TrailingIconLabelStyle.swift
//  DicomSwiftUI
//
//  Lays out SwiftUI labels with their icon after the text.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import SwiftUI

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle {
        TrailingIconLabelStyle()
    }
}
