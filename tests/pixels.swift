// Counts clearly red and clearly green pixels in an image, for telling fixture instances apart
// in screenshots (TESTAPP_PAD=red|green). usage: pixels <image>  ->  prints "<red> <green>"
import AppKit

guard CommandLine.arguments.count == 2,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("usage: pixels <image>\n".data(using: .utf8)!)
    exit(2)
}
let width = image.width, height = image.height
var bytes = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(2) }
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
var red = 0, green = 0
for i in stride(from: 0, to: bytes.count, by: 4) {
    let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
    if r > 180 && g < 100 && b < 100 { red += 1 } else if g > 180 && r < 130 && b < 130 { green += 1 }
}
print(red, green)
