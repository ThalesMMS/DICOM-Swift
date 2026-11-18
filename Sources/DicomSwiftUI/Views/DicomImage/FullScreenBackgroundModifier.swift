//
//  FullScreenBackgroundModifier.swift
//  DicomSwiftUI
//
//  Applies the image viewer background across the full screen.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import SwiftUI

struct FullScreenBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.ignoresSafeArea()
    }
}
