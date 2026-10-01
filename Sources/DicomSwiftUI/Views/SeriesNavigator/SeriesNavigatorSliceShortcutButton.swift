import SwiftUI

struct SeriesNavigatorSliceShortcutButton: View {
    let index: Int
    let isSelected: Bool
    let thumbnail: SeriesNavigatorThumbnail?
    let onSelect: () -> Void

    var body: some View {
        let fillColor = isSelected ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15)

        Button(action: onSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(fillColor)
                    .frame(width: 50, height: 50)

                if let thumbnail,
                   let cgImage = CGImageFactory.createImage(
                    from: thumbnail.pixels,
                    width: thumbnail.width,
                    height: thumbnail.height
                   ) {
                    Image(decorative: cgImage, scale: 1.0)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "photo")
                            .font(.caption2)
                        Text("\(index + 1)")
                            .font(.caption2)
                    }
                    .foregroundColor(isSelected ? .primary : .secondary)
                }

                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: 50, height: 50)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(
            thumbnail == nil
                ? "Slice \(index + 1) shortcut, thumbnail unavailable"
                : "Slice \(index + 1) thumbnail shortcut"
        )
        .accessibilityHint("Double tap to navigate to slice \(index + 1)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
