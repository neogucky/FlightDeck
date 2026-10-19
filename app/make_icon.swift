import AppKit

// Original icon built from a system symbol and vector paths; no downloaded artwork.
let size = NSSize(width:1024,height:1024)
let image = NSImage(size:size)
image.lockFocus()
NSColor(srgbRed:0.10,green:0.16,blue:0.23,alpha:1).setFill()
NSRect(origin:.zero,size:size).fill()
let orbit = NSBezierPath(ovalIn:NSRect(x:95,y:95,width:834,height:834))
orbit.lineWidth = 2
NSColor.white.withAlphaComponent(0.12).setStroke(); orbit.stroke()
let path = NSBezierPath()
path.move(to:NSPoint(x:140,y:230)); path.curve(to:NSPoint(x:810,y:810),controlPoint1:NSPoint(x:480,y:180),controlPoint2:NSPoint(x:750,y:530))
path.lineWidth = 8;path.setLineDash([16,18],count:2,phase:0)
NSColor.white.withAlphaComponent(0.3).setStroke();path.stroke()
NSColor(srgbRed:0.94,green:0.34,blue:0.16,alpha:1).setFill()
NSBezierPath(ovalIn:NSRect(x:123,y:213,width:34,height:34)).fill()
NSGraphicsContext.saveGraphicsState()
let transform = NSAffineTransform()
transform.translateX(by:520,yBy:540)
transform.concat()
let rotation = NSAffineTransform();rotation.rotate(byDegrees:34);rotation.concat()
if let symbol = NSImage(systemSymbolName:"airplane",accessibilityDescription:nil)?.withSymbolConfiguration(.init(paletteColors:[.white])) {
    symbol.draw(in:NSRect(x:-235,y:-235,width:470,height:470))
}
NSGraphicsContext.restoreGraphicsState()
image.unlockFocus()
let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
