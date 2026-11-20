import HarborCore
import UIKit

/// Reads a guest app's own icon out of its bundle.
///
/// Only from the image files the app names, never through its asset catalog.
/// `UIImage(named:in:)` looks in the catalog first, and when UIKit cannot
/// make an image of what it finds there it throws an Objective-C exception,
/// which Swift cannot catch: Instagram 454's catalog icon did, on iOS 27.2,
/// and Harbor closed every time the Library drew it (20 November 2026).
/// An app whose icon is only in its catalog shows the placeholder instead.
enum GuestIcon {
    /// The largest icon the app declares, or `nil` when it declares none
    /// that can be read.
    static func image(inBundleAt url: URL) -> UIImage? {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return nil }

        // Apps name their icon files in a few places, smallest first.
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let primary = (info[key] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any] else { continue }
            names += primary["CFBundleIconFiles"] as? [String] ?? []
            if let name = primary["CFBundleIconName"] as? String {
                names.append(name)
            }
        }
        names += info["CFBundleIconFiles"] as? [String] ?? []
        if let name = info["CFBundleIconFile"] as? String {
            names.append(name)
        }

        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        var best: UIImage?
        for file in files where names.contains(where: { iconFile(file, isNamed: $0) }) {
            // Reading a file returns nil for anything it cannot decode.
            guard let image = UIImage(contentsOfFile: url.appendingPathComponent(file).path) else { continue }
            if (image.size.width * image.scale) > (best.map { $0.size.width * $0.scale } ?? 0) {
                best = image
            }
        }
        return best
    }

    /// Whether `file` is one of the images an app's icon `name` stands for:
    /// `name.png`, with a scale (`@2x`, `@3x`) and a device (`~ipad`) or not.
    /// A name may already end in `.png`.
    static func iconFile(_ file: String, isNamed name: String) -> Bool {
        let base = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
        guard !base.isEmpty, file.hasPrefix(base), file.hasSuffix(".png") else { return false }
        var rest = Substring(file.dropFirst(base.count).dropLast(4))
        for device in ["~ipad", "~iphone"] where rest.hasSuffix(device) {
            rest = rest.dropLast(device.count)
        }
        return ["", "@2x", "@3x"].contains(String(rest))
    }

    /// A square PNG for a Home Screen shortcut. iOS rounds the corners.
    static func shortcutPNG(from image: UIImage, side: CGFloat = 180) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
