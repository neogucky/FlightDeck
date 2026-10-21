import SwiftUI
import UIKit

private enum AirframePhase { case ready, loading, returning, added }

/// A real add operation owns the busy state; a quick response still completes the morph.
struct AirframeActionButton: View {
    var title = "Add trip"
    var successTitle = "Trip added"
    var busyTitle = "Adding trip"
    var enabled = true
    var isAdded = false
    var identifier: String
    var onStart: () -> Void = {}
    var perform: () async -> Bool
    var onFinished: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = AirframePhase.ready
    @State private var started = Date.timeIntervalSinceReferenceDate
    private let entryDuration = 1.2
    private var reduced: Bool { reduceMotion || ProcessInfo.processInfo.arguments.contains("--uitesting-reduce-motion") }
    private var label: String {
        switch phase { case .ready: return title; case .loading,.returning: return busyTitle; case .added: return successTitle }
    }
    var body: some View {
        Button {
            guard enabled,phase == .ready else { return }
            started = Date.timeIntervalSinceReferenceDate;phase = .loading;onStart()
            Task { @MainActor in
                let succeeded = await perform()
                if succeeded {
                    let remaining = reduced ? 0:max(0,entryDuration-(Date.timeIntervalSinceReferenceDate-started))
                    if remaining>0 { try? await Task.sleep(for:.seconds(remaining)) }
                    started = Date.timeIntervalSinceReferenceDate;phase = .returning
                    if !reduced { try? await Task.sleep(for:.seconds(1.1)) }
                    phase = .added
                    // Keep the confirmation visible before the caller removes the row/sheet.
                    try? await Task.sleep(for:.milliseconds(900))
                } else { phase = .ready }
                onFinished(succeeded)
            }
        } label: {
            ZStack {
                Color.clear
                AirframeButtonDrawing(phase:phase,started:started,title:title,successTitle:successTitle,reduced:reduced)
                    .allowsHitTesting(false)
            }.frame(height:112).frame(maxWidth:.infinity).contentShape(Rectangle())
                .opacity(phase == .ready && !enabled ? 0.4:1)
                .accessibilityHidden(true)
        }.buttonStyle(AirframeButtonStyle()).disabled(!enabled || phase != .ready || isAdded)
            .accessibilityLabel(label).accessibilityIdentifier(identifier)
            .onChange(of:isAdded,initial:true) { _,value in if value,phase == .ready { phase = .added } }
    }
}

private struct AirframeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct AirframeButtonDrawing: UIViewRepresentable {
    let phase: AirframePhase
    let started: TimeInterval
    let title: String
    let successTitle: String
    let reduced: Bool
    func makeUIView(context: Context) -> AirframeDrawingView { AirframeDrawingView() }
    func updateUIView(_ view: AirframeDrawingView,context: Context) {
        view.phase = phase;view.started = started;view.title = title;view.successTitle = successTitle;view.reduced = reduced
        view.updateAnimation();view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: AirframeDrawingView,coordinator: ()) { view.stop() }
}

private final class AirframeDrawingView: UIView {
    var phase = AirframePhase.ready
    var started = Date.timeIntervalSinceReferenceDate
    var title = "Add trip"
    var successTitle = "Trip added"
    var reduced = false
    private var link: CADisplayLink?
    private lazy var clock = AirframeDisplayClock(view:self)
    private var letters: LetterMaterial?
    private let aircraft = FrontAircraft.shared
    private let navy = UIColor(red:26/255,green:41/255,blue:59/255,alpha:1)
    private let ivory = UIColor(red:248/255,green:248/255,blue:244/255,alpha:1)
    override init(frame: CGRect) { super.init(frame:frame);isOpaque = false;isUserInteractionEnabled = false;contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow();updateAnimation() }
    func updateAnimation() {
        let animate = window != nil && !reduced && (phase == .loading || phase == .returning)
        if animate,link == nil {
            let display = CADisplayLink(target:clock,selector:#selector(AirframeDisplayClock.tick))
            display.preferredFrameRateRange = CAFrameRateRange(minimum:30,maximum:60,preferred:60)
            display.add(to:.main,forMode:.common);link = display
        } else if !animate { stop() }
    }
    func stop() { link?.invalidate();link = nil }
    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext(),bounds.width>0,!aircraft.points.isEmpty else { return }
        let width = bounds.width,pw = min(216,width*0.9),now = Date.timeIntervalSinceReferenceDate
        let exiting = phase == .returning || phase == .added
        let entry: CGFloat = phase == .ready ? 0:reduced || exiting ? 1:clamp(CGFloat((now-started)/1.2))
        let exit: CGFloat = phase == .added ? 1:phase == .returning ? (reduced ? 1:clamp(CGFloat((now-started)/1.1))):0
        let top = aircraft.points.map { mapped($0,lower:false,width:width,pw:pw,entry:entry,exit:exit,exiting:exiting) }
        let bottom = aircraft.points.map { mapped($0,lower:true,width:width,pw:pw,entry:entry,exit:exit,exiting:exiting) }
        let path = outline(top,bottom)
        (exiting ? ivory:navy).setFill();path.fill()
        cg.saveGState();path.addClip()
        let format = UIGraphicsImageRendererFormat();format.scale = min(window?.screen.scale ?? 2,2);format.opaque = false
        let size = CGSize(width:width,height:112)
        var inkImage: UIImage?
        if !exiting {
            let key = "\(title)|\(width)"
            if letters?.key != key { letters = LetterMaterial(title:title,width:width,key:key) }
            inkImage = letters?.image(width:width,scale:format.scale,progress:entry,points:aircraft.points,top:top,bottom:bottom)
            inkImage?.draw(in:CGRect(origin:.zero,size:size))
        }
        let texture = UIGraphicsImageRenderer(size:size,format:format).image { render in
            var locations = [CGFloat](),alphas = [CGFloat]()
            for i in aircraft.strips.indices {
                let strip = aircraft.strips[i],point = aircraft.points[i]
                let dx = top[i].x,dw = top[i+1].x-dx,dy = (top[i].y+top[i+1].y)/2
                let dh = (bottom[i].y+bottom[i+1].y)/2-dy
                guard dw>0,dh>0 else { continue }
                strip.image.draw(in:CGRect(x:dx,y:dy,width:dw+0.4,height:dh))
                let edge = abs(point.q-0.5)*2
                let detail = exiting ? 1-ramp(0.02,0.68,exit):ramp(0.23+0.18*edge,0.96,entry)
                let similarity = ramp(0.25,0.92,strip.sourceHeight*pw/aircraft.sourceWidth/dh)
                locations.append(clamp((dx+dw/2)/width));alphas.append(detail*similarity)
            }
            if let first = alphas.first,let last = alphas.last {
                locations.insert(0,at:0);locations.append(1);alphas.insert(first,at:0);alphas.append(last)
                let components: [CGFloat] = alphas.flatMap { [CGFloat(0),CGFloat(0),CGFloat(0),$0] }
                if let gradient = CGGradient(colorSpace:CGColorSpaceCreateDeviceRGB(),colorComponents:components,locations:locations,count:locations.count) {
                    render.cgContext.setBlendMode(.destinationIn)
                    render.cgContext.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:width,y:0),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
                }
                if let inkImage { inkImage.draw(in:CGRect(origin:.zero,size:size),blendMode:.destinationIn,alpha:1) }
            }
        }
        texture.draw(in:CGRect(origin:.zero,size:size));cg.restoreGState()
        let stroke: CGFloat = exiting ? 0.56:mix(0.66,0.32,ramp(0.35,1,entry))
        navy.withAlphaComponent(stroke).setStroke();path.lineWidth = 1.1;path.lineJoinStyle = .round;path.stroke()
        let propOpacity = exiting ? 1-ramp(0.03,0.44,exit):ramp(0.34,0.78,entry)
        for engine in 0..<2 where propOpacity>0 {
            let sourceX: CGFloat = engine == 0 ? 0.3695:0.6305
            var i = 1
            while i<aircraft.points.count-1,aircraft.points[i].x<sourceX { i+=1 }
            let before = aircraft.points[i-1],after = aircraft.points[i]
            let t = clamp((sourceX-before.x)/(after.x-before.x))
            let sourceTop = mix(before.top,after.top,t),sourceBottom = mix(before.bottom,after.bottom,t)
            let x = mix(top[i-1].x,top[i].x,t),yTop = mix(top[i-1].y,top[i].y,t),yBottom = mix(bottom[i-1].y,bottom[i].y,t)
            let y = mix(yTop,yBottom,clamp((0.662-sourceTop)/(sourceBottom-sourceTop)))
            let diameter = pw*0.16*mix(0.8,1,propOpacity)
            cg.saveGState();cg.translateBy(x:x,y:y)
            let angle = reduced ? CGFloat(engine)*0.7:CGFloat((now-started+(engine == 0 ? 0:0.13))/0.36)*2*CGFloat.pi
            cg.rotate(by:angle);navy.withAlphaComponent(propOpacity).setFill()
            for _ in 0..<3 {
                UIBezierPath(roundedRect:CGRect(x:-0.8,y:0,width:1.6,height:diameter*0.48),cornerRadius:0.8).fill();cg.rotate(by:2*CGFloat.pi/3)
            }
            UIBezierPath(ovalIn:CGRect(x:-diameter*0.07,y:-diameter*0.07,width:diameter*0.14,height:diameter*0.14)).fill();cg.restoreGState()
        }
        if exiting { drawConfirmation(width:width,opacity:ramp(0.64,1,exit)) }
    }
    private func mapped(_ p: FrontAircraft.Point,lower: Bool,width: CGFloat,pw: CGFloat,entry: CGFloat,exit: CGFloat,exiting: Bool) -> CGPoint {
        let t = smooth(exiting ? exit:entry),endWidth = min(184,width*0.78)
        let a: CGPoint,b: CGPoint,c: CGPoint,d: CGPoint
        if exiting {
            a = plane(p,lower:lower,outer:width,width:pw);b = plane(p,lower:lower,outer:width,width:pw*0.94)
            c = oval(p,lower:lower,outer:width,width:endWidth,height:44);d = oval(p,lower:lower,outer:width,width:endWidth,height:48)
        } else {
            a = rounded(p,lower:lower,outer:width,width:width,height:56,radius:16)
            b = rounded(p,lower:lower,outer:width,width:mix(pw,width,0.2),height:46,radius:23)
            c = plane(p,lower:lower,outer:width,width:pw*0.9);d = plane(p,lower:lower,outer:width,width:pw)
        }
        return CGPoint(x:bezier(a.x,b.x,c.x,d.x,t),y:bezier(a.y,b.y,c.y,d.y,t))
    }
    private func drawConfirmation(width: CGFloat,opacity: CGFloat) {
        guard opacity>0 else { return }
        let font = UIFont.systemFont(ofSize:13,weight:.medium),color = navy.withAlphaComponent(0.78*opacity)
        let textWidth = (successTitle as NSString).size(withAttributes:[.font:font]).width
        let left = (width-textWidth-23)/2
        UIImage(systemName:"checkmark",withConfiguration:UIImage.SymbolConfiguration(pointSize:13,weight:.medium))?
            .withTintColor(color,renderingMode:.alwaysOriginal).draw(in:CGRect(x:left,y:49,width:14,height:14))
        (successTitle as NSString).draw(at:CGPoint(x:left+23,y:48),withAttributes:[.font:font,.foregroundColor:color])
    }
}

private final class AirframeDisplayClock: NSObject {
    weak var view: AirframeDrawingView?
    init(view: AirframeDrawingView) { self.view = view }
    @objc func tick() { view?.setNeedsDisplay() }
}

private final class FrontAircraft {
    struct Point { var x: CGFloat;var top: CGFloat;var bottom: CGFloat;var q: CGFloat = 0 }
    struct Strip { var image: UIImage;var sourceHeight: CGFloat }
    static let shared = FrontAircraft()
    var points = [Point](),strips = [Strip]();var sourceWidth: CGFloat = 1
    private init() {
        guard let original = UIImage(named:"DC3Front"),let cg = original.cgImage else { return }
        sourceWidth = CGFloat(cg.width)
        let format = UIGraphicsImageRendererFormat();format.scale = 1
        let thumbnail = UIGraphicsImageRenderer(size:CGSize(width:480,height:160),format:format).image { _ in original.draw(in:CGRect(x:0,y:0,width:480,height:160)) }
        guard let raw = rgba(thumbnail) else { return }
        for x in stride(from:2,to:479,by:2) {
            var upper = 160,lower = -1
            for y in 0..<160 where raw[(y*480+x)*4+3]>64 { upper = min(upper,y);lower = max(lower,y) }
            if lower>=upper { points.append(Point(x:CGFloat(x)/480,top:CGFloat(upper)/160,bottom:CGFloat(lower+1)/160)) }
        }
        guard let first = points.first?.x,let last = points.last?.x else { return }
        for i in points.indices { points[i].q = (points[i].x-first)/(last-first) }
        for i in 0..<max(0,points.count-1) {
            let a = points[i],b = points[i+1],sy = (a.top+b.top)/2*CGFloat(cg.height)
            let sh = max(1,((a.bottom+b.bottom)-(a.top+b.top))/2*CGFloat(cg.height))
            let rect = CGRect(x:a.x*CGFloat(cg.width),y:sy,width:(b.x-a.x)*CGFloat(cg.width),height:sh).integral.intersection(CGRect(x:0,y:0,width:cg.width,height:cg.height))
            if let cropped = cg.cropping(to:rect) { strips.append(Strip(image:UIImage(cgImage:cropped),sourceHeight:sh)) }
        }
    }
}

private final class LetterMaterial {
    let key: String
    private var w = 0,h = 0,base = [Float](),distance = [Float](),alpha = [Float](),maxDistance: Float = 0
    private var left: CGFloat = 0,top: CGFloat = 0,width: CGFloat = 0,height: CGFloat = 0
    init(title: String,width outer: CGFloat,key: String) {
        self.key = key
        let font = UIFont.systemFont(ofSize:15,weight:.semibold),plus = UIFont.systemFont(ofSize:20,weight:.regular)
        let textWidth = (title as NSString).size(withAttributes:[.font:font]).width
        let box = CGSize(width:ceil(textWidth+33),height:27),format = UIGraphicsImageRendererFormat();format.scale = 3
        let source = UIGraphicsImageRenderer(size:box,format:format).image { _ in
            (title as NSString).draw(at:CGPoint(x:29,y:(box.height-font.lineHeight)/2),withAttributes:[.font:font,.foregroundColor:UIColor.white])
            let plusWidth = ("+" as NSString).size(withAttributes:[.font:plus]).width
            ("+" as NSString).draw(at:CGPoint(x:12-plusWidth/2,y:(box.height-plus.lineHeight)/2),withAttributes:[.font:plus,.foregroundColor:UIColor.white])
        }
        guard let cg = source.cgImage,let pixels = rgba(source) else { return }
        var x0 = cg.width,x1 = 0,y0 = cg.height,y1 = 0
        for y in 0..<cg.height { for x in 0..<cg.width where pixels[(y*cg.width+x)*4+3]>0 {
            x0 = min(x0,x);x1 = max(x1,x);y0 = min(y0,y);y1 = max(y1,y)
        } }
        w = x1-x0+1;h = y1-y0+1
        guard w>0,h>0 else { return }
        base = [Float](repeating:0,count:w*h);distance = [Float](repeating:10000,count:w*h);alpha = base
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x,a = Float(pixels[((y+y0)*cg.width+x+x0)*4+3])/255;base[i] = a;distance[i] = a>0.5 ? 0:10000
        } }
        let diagonal = Float(2).squareRoot()
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x
            if x>0 { distance[i] = min(distance[i],distance[i-1]+1) }
            if y>0 { distance[i] = min(distance[i],distance[i-w]+1) }
            if x>0,y>0 { distance[i] = min(distance[i],distance[i-w-1]+diagonal) }
            if x+1<w,y>0 { distance[i] = min(distance[i],distance[i-w+1]+diagonal) }
        } }
        for y in (0..<h).reversed() { for x in (0..<w).reversed() {
            let i = y*w+x
            if x+1<w { distance[i] = min(distance[i],distance[i+1]+1) }
            if y+1<h { distance[i] = min(distance[i],distance[i+w]+1) }
            if x+1<w,y+1<h { distance[i] = min(distance[i],distance[i+w+1]+diagonal) }
            if x>0,y+1<h { distance[i] = min(distance[i],distance[i+w-1]+diagonal) }
        } }
        maxDistance = distance.max() ?? 0
        left = (outer-box.width)/2+CGFloat(x0)/3;top = 56-box.height/2+CGFloat(y0)/3
        width = CGFloat(w)/3;height = CGFloat(h)/3
    }
    func image(width outer: CGFloat,scale: CGFloat,progress p: CGFloat,points: [FrontAircraft.Point],top upper: [CGPoint],bottom lower: [CGPoint]) -> UIImage? {
        guard w>0,h>0 else { return nil }
        let spread = Float(ramp(0.22,0.86,p))*(maxDistance+1.5)
        for i in alpha.indices { alpha[i] = max(base[i],Float(smooth(CGFloat((spread+0.75-distance[i])/1.5)))) }
        let warpX = ramp(0.08,0.82,p),warpY = ramp(0.12,0.88,p)
        let x0 = mix(left,upper[0].x,warpX),x1 = mix(left+width,upper.last!.x,warpX)
        let outputW = Int(ceil(outer*scale)),outputH = Int(ceil(112*scale))
        var bytes = [UInt8](repeating:0,count:outputW*outputH*4),segment = 0
        for px in max(0,Int(floor(x0*scale)))..<min(outputW,Int(ceil(x1*scale))) {
            let q = clamp(((CGFloat(px)+0.5)/scale-x0)/(x1-x0))
            while segment<points.count-2,points[segment+1].q<q { segment+=1 }
            let t = clamp((q-points[segment].q)/(points[segment+1].q-points[segment].q))
            let y0 = mix(top,mix(upper[segment].y,upper[segment+1].y,t),warpY)
            let y1 = mix(top+height,mix(lower[segment].y,lower[segment+1].y,t),warpY)
            let sx = q*CGFloat(w-1),ix = Int(floor(sx)),jx = min(w-1,ix+1),tx = Float(sx-CGFloat(ix))
            for py in max(0,Int(floor(y0*scale)))..<min(outputH,Int(ceil(y1*scale))) {
                let sy = clamp(((CGFloat(py)+0.5)/scale-y0)/(y1-y0))*CGFloat(h-1),iy = Int(floor(sy)),jy = min(h-1,iy+1),ty = Float(sy-CGFloat(iy))
                let a = alpha[iy*w+ix]+(alpha[iy*w+jx]-alpha[iy*w+ix])*tx
                let b = alpha[jy*w+ix]+(alpha[jy*w+jx]-alpha[jy*w+ix])*tx
                let opacity = max(0,min(1,a+(b-a)*ty)),i = (py*outputW+px)*4
                bytes[i] = UInt8(248*opacity);bytes[i+1] = UInt8(248*opacity);bytes[i+2] = UInt8(244*opacity);bytes[i+3] = UInt8(255*opacity)
            }
        }
        guard let provider = CGDataProvider(data:Data(bytes) as CFData),let cg = CGImage(width:outputW,height:outputH,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:outputW*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return nil }
        return UIImage(cgImage:cg,scale:scale,orientation:.up)
    }
}

private func rgba(_ image: UIImage) -> [UInt8]? {
    guard let cg = image.cgImage else { return nil }
    var bytes = [UInt8](repeating:0,count:cg.width*cg.height*4)
    let ok = bytes.withUnsafeMutableBytes { ptr -> Bool in
        guard let ctx = CGContext(data:ptr.baseAddress,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height));return true
    }
    return ok ? bytes:nil
}
private func clamp(_ value: CGFloat) -> CGFloat { max(0,min(1,value)) }
private func mix(_ a: CGFloat,_ b: CGFloat,_ t: CGFloat) -> CGFloat { a+(b-a)*t }
private func smooth(_ n: CGFloat) -> CGFloat { let t = clamp(n);return t*t*(3-2*t) }
private func ramp(_ a: CGFloat,_ b: CGFloat,_ t: CGFloat) -> CGFloat { smooth((t-a)/(b-a)) }
private func bezier(_ a: CGFloat,_ b: CGFloat,_ c: CGFloat,_ d: CGFloat,_ t: CGFloat) -> CGFloat { pow(1-t,3)*a+3*pow(1-t,2)*t*b+3*(1-t)*t*t*c+t*t*t*d }
private func rounded(_ p: FrontAircraft.Point,lower: Bool,outer: CGFloat,width: CGFloat,height: CGFloat,radius: CGFloat) -> CGPoint {
    let x = 0.9+p.q*(width-1.8),w = width-1.8,local = x-0.9
    let corner = local<radius ? radius-local:local>w-radius ? local-(w-radius):0
    let inset = corner>0 ? radius-sqrt(max(0,radius*radius-corner*corner)):0
    return CGPoint(x:(outer-width)/2+x,y:56+(lower ? 1:-1)*(height/2-inset))
}
private func plane(_ p: FrontAircraft.Point,lower: Bool,outer: CGFloat,width: CGFloat) -> CGPoint {
    CGPoint(x:(outer-width)/2+p.x*width,y:56-width/6+(lower ? p.bottom:p.top)*width/3)
}
private func oval(_ p: FrontAircraft.Point,lower: Bool,outer: CGFloat,width: CGFloat,height: CGFloat) -> CGPoint {
    let u = p.q*2-1,y = height/2*pow(max(0,1-pow(abs(u),2.4)),1/2.4)
    return CGPoint(x:(outer-width)/2+p.q*width,y:56+(lower ? y:-y))
}
private func outline(_ top: [CGPoint],_ bottom: [CGPoint]) -> UIBezierPath {
    let path = UIBezierPath();guard let first = top.first else { return path }
    path.move(to:first);for point in top.dropFirst() { path.addLine(to:point) };for point in bottom.reversed() { path.addLine(to:point) };path.close();return path
}
