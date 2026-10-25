import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let bounds = NSRect(origin: .zero, size: size)
NSGradient(starting: NSColor(calibratedRed: 0.32, green: 0.83, blue: 0.91, alpha: 1), ending: NSColor(calibratedRed: 0.46, green: 0.36, blue: 0.88, alpha: 1))!.draw(in: bounds, angle: -45)
let style = NSMutableParagraphStyle(); style.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 570), .foregroundColor: NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.13, alpha: 1), .paragraphStyle: style]
("融" as NSString).draw(in: NSRect(x: 0, y: 130, width: 1024, height: 780), withAttributes: attributes)
image.unlockFocus()
let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: "Fusion/Assets.xcassets/AppIcon.appiconset/Icon.png"))
