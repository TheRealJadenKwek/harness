import SwiftUI
import UIKit

/// Downscale + JPEG-compress so uploads stay small (Claude tops out usefully ~1568px).
func downscaledJPEG(_ image: UIImage, maxDim: CGFloat = 1568, quality: CGFloat = 0.6) -> Data? {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return image.jpegData(compressionQuality: quality) }
    let scale = min(1, maxDim / max(size.width, size.height))
    if scale >= 1 { return image.jpegData(compressionQuality: quality) }
    let newSize = CGSize(width: size.width * scale, height: size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: newSize)
    let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    return scaled.jpegData(compressionQuality: quality)
}

struct PendingImagesStrip: View {
    @Binding var images: [Data]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, data in
                    if let ui = UIImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: ui)
                                .resizable().scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button {
                                images.remove(at: idx)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 5, y: -5)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
    }
}
