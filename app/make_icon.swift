import AppKit
import CoreText

// Rebuild with: swift app/make_icon.swift
// Uses the approved DC-3 mark for both Departure and the home-screen icon.
let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("FlightDeck")
let ivory = NSColor(srgbRed:245/255,green:244/255,blue:238/255,alpha:1)
let mark = NSImage(contentsOf:root.appendingPathComponent("Brand/DC3Mark.png"))!
CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Brand/SpaceGrotesk.ttf") as CFURL,.process,nil)

func render(_ size: CGSize, scale: CGFloat = 1, opaque: Bool = false, draw: (CGContext) -> Void) -> Data {
    let context = CGContext(data:nil,width:Int(size.width*scale),height:Int(size.height*scale),bitsPerComponent:8,bytesPerRow:0,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:(opaque ? CGImageAlphaInfo.noneSkipLast:CGImageAlphaInfo.premultipliedLast).rawValue)!
    context.scaleBy(x:scale,y:scale);context.translateBy(x:0,y:size.height);context.scaleBy(x:1,y:-1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:])!
}
func aircraft(_ context: CGContext, centre: CGPoint, width: CGFloat, angle: CGFloat) {
    context.saveGState();context.translateBy(x:centre.x,y:centre.y);context.rotate(by:angle)
    // Tint the actual alpha silhouette; ignore hidden RGB around the generated mark.
    context.beginTransparencyLayer(auxiliaryInfo:nil)
    mark.draw(in:CGRect(x:-width/2,y:-width/3,width:width,height:width*2/3))
    context.setBlendMode(.sourceIn);context.setFillColor(ivory.cgColor)
    context.fill(CGRect(x:-width/2,y:-width/3,width:width,height:width*2/3))
    context.endTransparencyLayer();context.restoreGState()
}
func font(_ weight: Double) -> NSFont {
    let base = CTFontCreateWithName("SpaceGrotesk-Regular" as CFString,43,nil)
    let descriptor = CTFontDescriptorCreateCopyWithVariation(CTFontCopyFontDescriptor(base),NSNumber(value:0x77676874),CGFloat(weight))
    return CTFontCreateWithFontDescriptor(descriptor,43,nil) as NSFont
}
let words = NSMutableAttributedString(string:"Flight",attributes:[.font:font(500),.foregroundColor:ivory,.kern:-2.8])
words.append(NSAttributedString(string:"Deck",attributes:[.font:font(700),.foregroundColor:ivory,.kern:-2.8]))
let width = ceil(words.size().width)+8
let logo = render(CGSize(width:width,height:129),scale:4) { c in
    c.translateBy(x:0,y:26)
    c.saveGState();c.translateBy(x:4,y:46)
    c.concatenate(CGAffineTransform(a:1,b:0,c:-tan(7 * .pi/180),d:1,tx:3,ty:0))
    words.draw(at:.zero);c.restoreGState()
    let trail = NSBezierPath()
    trail.move(to:NSPoint(x:width-159,y:48))
    trail.curve(to:NSPoint(x:width-54,y:21),controlPoint1:NSPoint(x:width-112,y:48),controlPoint2:NSPoint(x:width-82,y:39))
    trail.lineWidth = 1.5;ivory.withAlphaComponent(0.55).setStroke();trail.stroke()
    aircraft(c,centre:CGPoint(x:width-41,y:23),width:68,angle:55 * .pi/180)
}
try logo.write(to:root.appendingPathComponent("Assets.xcassets/DepartureLogo.imageset/DepartureLogo.png"))
let icon = render(CGSize(width:1024,height:1024),opaque:true) { c in
    let colors = [NSColor(srgbRed:0.10,green:0.16,blue:0.23,alpha:1).cgColor,
                  NSColor(srgbRed:0.16,green:0.27,blue:0.34,alpha:1).cgColor]
    let gradient = CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors as CFArray,locations:[0,1])!
    c.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:1024,y:1024),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    let trail = NSBezierPath()
    trail.move(to:NSPoint(x:177,y:784))
    trail.curve(to:NSPoint(x:622,y:420),controlPoint1:NSPoint(x:450,y:817),controlPoint2:NSPoint(x:379,y:550))
    trail.lineWidth = 12;trail.lineCapStyle = .round;ivory.withAlphaComponent(0.60).setStroke();trail.stroke()
    aircraft(c,centre:CGPoint(x:601,y:396),width:574,angle:55 * .pi/180)
}
try icon.write(to:root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
print("Rebuilt Departure logo and 1024px app icon")
