import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum DownloadQR {
    static func image(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale: CGFloat = 8
        let quietZone = 4 * scale
        let code = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: quietZone, y: quietZone))
        let frame = code.extent.insetBy(dx: -quietZone, dy: -quietZone)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: frame)
        let image = code.composited(over: white)
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: frame)
    }
}
