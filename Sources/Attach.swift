import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Turns what iOS hands over (photos, camera shots, pasted images, files) into files a coding
/// agent can read: JPEG or PNG at most 2048 px on the long side, HEIC converted.
enum Attachments {
    static let maxSide: CGFloat = 2048

    static func stamp(_ index: Int, of count: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: .now) + (count > 1 ? "-\(index + 1)" : "")
    }

    static func scaled(_ image: UIImage) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let k = maxSide / side
        let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Photos as JPEG; a screenshot reads better as PNG, so pasted images stay PNG.
    static func photo(_ image: UIImage, name: String) -> BlockStream.Attachment? {
        scaled(image).jpegData(compressionQuality: 0.85).map { .init(name: name + ".jpg", data: $0) }
    }

    static func screenshot(_ image: UIImage, name: String) -> BlockStream.Attachment? {
        scaled(image).pngData().map { .init(name: name + ".png", data: $0) }
    }

    static func photos(_ items: [PhotosPickerItem]) async -> [BlockStream.Attachment] {
        var out: [BlockStream.Attachment] = []
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                  let a = photo(image, name: "photo-" + stamp(i, of: items.count)) else { continue }
            out.append(a)
        }
        return out
    }

    /// Files as they are, except HEIC, which agents can't read, made JPEG.
    static func files(_ urls: [URL]) -> [BlockStream.Attachment] {
        urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .heic) || type.conforms(to: .heif),
               let image = UIImage(data: data) {
                return photo(image, name: url.deletingPathExtension().lastPathComponent)
            }
            return .init(name: url.lastPathComponent, data: data)
        }
    }
}

/// The camera, for a photo to attach on the spot.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
