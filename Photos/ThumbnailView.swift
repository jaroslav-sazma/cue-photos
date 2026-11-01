import SwiftUI

struct ThumbnailView: View {
    @Environment(AppModel.self) private var model
    let base: String?
    let cacheKey: String
    let side: CGFloat

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: side, height: side)
        .task(id: base) {
            guard let base else { return }
            image = try? await model.thumbnails.thumbnail(
                base: base,
                pixelSize: Int(side) * 2,
                cacheKey: cacheKey
            )
        }
    }
}
