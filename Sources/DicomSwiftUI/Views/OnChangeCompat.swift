//
//  OnChangeCompat.swift
//  DicomSwiftUI
//
//  Shared SwiftUI onChange helper preserving the package call-site shape.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import SwiftUI

extension View {
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        fallback _: Published<Value>.Publisher,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        self.onChange(of: value) { _, newValue in
            action(newValue)
        }
    }
}
