import AppKit
let source=URL(fileURLWithPath:"Fusion/Assets.xcassets/AppIcon.appiconset/Icon.png")
let data=try Data(contentsOf:source)
guard let image=NSBitmapImageRep(data:data),image.pixelsWide==1024,image.pixelsHigh==1024,!image.hasAlpha else { fatalError("Expected opaque 1024px PC artwork") }
