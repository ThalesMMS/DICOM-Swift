import SwiftUI

struct FullScreenBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.ignoresSafeArea()
    }
}
