import HarborCore
import UIKit

/// Reads a guest app's own icon out of its bundle.
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

        var best: UIImage?
        for name in names {
            guard let image = UIImage(named: name, in: bundle, compatibleWith: nil) else { continue }
            if (image.size.width * image.scale) > (best.map { $0.size.width * $0.scale } ?? 0) {
                best = image
            }
        }
        return best
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
