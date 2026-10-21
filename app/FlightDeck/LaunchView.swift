import SwiftUI
import UIKit

/// Resolve the actual visible card instead of assuming a particular screen size or itinerary.
struct LaunchCardPreference: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    func launchCard() -> some View { anchorPreference(key:LaunchCardPreference.self,value:.bounds) { $0 } }
}

struct LaunchCover: View {
    let destination: CGRect?
    let finished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NativeLaunchAnimation(destination:destination,reduceMotion:reduceMotion || testReduceMotion,finished:finished)
            .accessibilityLabel("FlightDeck is taking off")
            .accessibilityIdentifier("launchAnimation")
            .onChange(of:phase) { _,value in if value == .background { finished() } }
    }
    private var testReduceMotion: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--uitesting-launch") && args.contains("--uitesting-reduce-motion")
        #else
        return false
        #endif
    }
}

private struct NativeLaunchAnimation: UIViewRepresentable {
    let destination: CGRect?
    let reduceMotion: Bool
    let finished: () -> Void
    func makeUIView(context: Context) -> TakeoffView {
        let view = TakeoffView()
        view.destination = destination;view.reduceMotion = reduceMotion;view.finished = finished
        return view
    }
    func updateUIView(_ view: TakeoffView, context: Context) {
        view.destination = destination;view.reduceMotion = reduceMotion;view.finished = finished
    }
    static func dismantleUIView(_ view: TakeoffView, coordinator: ()) { view.stop() }
}

/// Core Graphics runs the approved 2.5D scene locally. No web view, audio, or network dependency.
private final class TakeoffView: UIView {
    var destination: CGRect?
    var reduceMotion = false
    var finished: (() -> Void)?
    private var displayLink: CADisplayLink?
    private var started: CFTimeInterval?
    private var seconds: CGFloat = 0
    private var completed = false
    private var transitionTarget: CGRect?
    private var capturedTarget = false
    private let airframe = UIImage(named:"DC3Airframe")
    private let logo = UIImage(named:"DepartureLogo")
    private lazy var shadow = airframe?.withTintColor(.black,renderingMode:.alwaysOriginal)
    private let startup: CGFloat = 1.5
    private let takeoff: CGFloat = 4.6
    private let hold: CGFloat = 0.25
    private let reveal: CGFloat = 1
    private static let ink = UIColor(red:0.10,green:0.16,blue:0.23,alpha:1)
    private static let paper = UIColor(red:0.96,green:0.96,blue:0.94,alpha:1)
    private static let ivory = UIColor(red:245/255,green:244/255,blue:238/255,alpha:1)
    private let gradient = CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),
        colors:[TakeoffView.ink.cgColor,UIColor(red:0.16,green:0.27,blue:0.34,alpha:1).cgColor] as CFArray,locations:[0,1])!

    // CADisplayLink retains its target. A weak proxy lets dismantling release the whole scene.
    private final class FrameTarget: NSObject {
        weak var view: TakeoffView?
        init(_ view: TakeoffView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
    }
    override init(frame: CGRect) {
        super.init(frame:frame)
        backgroundColor = .clear;isOpaque = false;isAccessibilityElement = true
        accessibilityLabel = "FlightDeck is taking off";isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop();return }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--uitesting-launch"),let frame = args.first(where:{ $0.hasPrefix("--uitesting-launch-frame=") }),
           let value = Double(frame.replacingOccurrences(of:"--uitesting-launch-frame=",with:"")) {
            seconds = CGFloat(value);setNeedsDisplay();return
        }
        #endif
        guard displayLink == nil,!completed else { return }
        let link = CADisplayLink(target:FrameTarget(self),selector:#selector(FrameTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum:30,maximum:30,preferred:30)
        displayLink = link;link.add(to:.main,forMode:.common)
    }
    func stop() { displayLink?.invalidate();displayLink = nil }
    private func tick(_ link: CADisplayLink) {
        if started == nil { started = link.timestamp }
        seconds = CGFloat(link.timestamp-(started ?? link.timestamp))
        let duration: CGFloat = reduceMotion ? 0.45:startup+takeoff+hold+reveal
        guard seconds < duration else {
            stop();guard !completed else { return };completed = true;finished?();return
        }
        setNeedsDisplay()
    }
    private func clamp(_ value: CGFloat) -> CGFloat { min(1,max(0,value)) }
    private func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a+(b-a)*t }
    private func smooth(_ value: CGFloat) -> CGFloat { let t = clamp(value);return t*t*(3-2*t) }
    private struct Plane {
        var x: CGFloat
        var y: CGFloat
        var lift: CGFloat
    }
    private func geometry(_ flight: CGFloat) -> Plane {
        let roll = clamp(flight/0.30),flying = clamp((flight-0.26)/0.58)
        let distance = 0.12*roll*roll+0.88*smooth(flying)
        return Plane(x:bounds.width*0.5,y:bounds.height*(0.79-distance*0.94),lift:smooth(flying*2))
    }
    private func project(_ g: Plane, _ pw: CGFloat, _ ph: CGFloat, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat = 0) -> CGPoint {
        let pitch = 0.045+g.lift*32 * .pi/180,pivot = -ph*0.075,focal = pw*2.1
        let py = (y-pivot)*cos(pitch)+z*sin(pitch)
        let pz = -(y-pivot)*sin(pitch)+z*cos(pitch)
        let perspective = focal/(focal-pz)
        return CGPoint(x:g.x+x*perspective,y:g.y-g.lift*9+(py+pivot)*perspective)
    }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext(),bounds.width>0,bounds.height>0 else { return }
        if reduceMotion {
            let opacity = 1-smooth((seconds-0.15)/0.30)
            c.setAlpha(opacity);fillBlanket(c,in:bounds)
            drawLogo(c,centre:CGPoint(x:bounds.midX,y:bounds.height*0.485),width:logoWidth,opacity:opacity)
        } else if seconds < startup+takeoff {
            drawTakeoff(c)
        } else {
            drawReveal(c)
        }
    }
    private var logoWidth: CGFloat { min(285,bounds.width*0.67) }
    private func fillBlanket(_ c: CGContext, in rect: CGRect) {
        c.drawLinearGradient(gradient,start:rect.origin,end:CGPoint(x:rect.maxX,y:rect.maxY),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    }
    private func drawLogo(_ c: CGContext, centre: CGPoint, width: CGFloat, opacity: CGFloat = 1) {
        guard let logo else { return }
        let height = width*logo.size.height/logo.size.width
        // UIImage's convenience draw uses its own alpha; pass the fade explicitly.
        logo.draw(in:CGRect(x:centre.x-width/2,y:centre.y-height/2,width:width,height:height),blendMode:.normal,alpha:opacity)
    }
    private func drawReveal(_ c: CGContext) {
        let p = clamp((seconds-startup-takeoff-hold)/reveal),e = 1-pow(1-p,3)
        if !capturedTarget { transitionTarget = destination;capturedTarget = true }
        c.saveGState();c.setFillColor(Self.paper.cgColor);c.setAlpha(1-smooth(p/0.62));c.fill(bounds);c.restoreGState()
        let target = transitionTarget ?? bounds
        let sheet = CGRect(x:mix(0,target.minX,e),y:mix(0,target.minY,e),
            width:mix(bounds.width,target.width,e),height:mix(bounds.height,target.height,e))
        c.saveGState();c.setAlpha(1-smooth((p-0.73)/0.27))
        c.addPath(UIBezierPath(roundedRect:sheet,cornerRadius:transitionTarget == nil ? 0:28*e).cgPath);c.clip()
        fillBlanket(c,in:sheet)
        let logoOpacity = (1-smooth((p-0.28)/0.35))*(1-smooth((p-0.73)/0.27))
        drawLogo(c,centre:CGPoint(x:sheet.midX,y:sheet.minY+sheet.height*0.485),width:logoWidth*mix(1,0.88,e),opacity:logoOpacity)
        c.restoreGState()
    }
    private func drawTakeoff(_ c: CGContext) {
        Self.paper.setFill();c.fill(bounds)
        let flight = clamp((seconds-startup)/takeoff),g = geometry(flight)
        drawRunway(c,flight:flight)
        let pw = bounds.width*0.56,ph = pw*2/3,tail = project(g,pw,ph,0,ph*0.48)
        let reach = max(bounds.width,bounds.height)*3,sag: CGFloat = 70
        let cloth = UIBezierPath()
        cloth.move(to:CGPoint(x:tail.x-reach,y:tail.y+reach))
        cloth.addLine(to:CGPoint(x:tail.x-reach,y:tail.y+sag+reach*0.03))
        cloth.addCurve(to:tail,controlPoint1:CGPoint(x:tail.x-bounds.width*0.5,y:tail.y+sag),controlPoint2:CGPoint(x:tail.x-29,y:tail.y+9))
        cloth.addCurve(to:CGPoint(x:tail.x+reach,y:tail.y+sag+reach*0.03),controlPoint1:CGPoint(x:tail.x+29,y:tail.y+9),controlPoint2:CGPoint(x:tail.x+bounds.width*0.5,y:tail.y+sag))
        cloth.addLine(to:CGPoint(x:tail.x+reach,y:tail.y+reach));cloth.close()
        let finalTail = project(geometry(1),pw,ph,0,ph*0.48)
        // Logo and gradient use a fixed material coordinate, moving with the cloth.
        let travel = tail.y-finalTail.y
        c.saveGState();cloth.addClip();fillBlanket(c,in:bounds.offsetBy(dx:0,dy:travel))
        drawLogo(c,centre:CGPoint(x:bounds.midX,y:bounds.height*0.485+travel),width:logoWidth);c.restoreGState()
        if let shadow {
            c.saveGState()
            c.setShadow(offset:.zero,blur:1+g.lift*4,color:UIColor.black.cgColor)
            shadow.draw(in:CGRect(x:g.x-pw/2+2+g.lift*10,y:g.y-ph/2+3+g.lift*18,width:pw,height:ph),blendMode:.normal,alpha:mix(0.18,0.13,g.lift))
            c.restoreGState()
        }
        drawAirframe(c,g:g,pw:pw,ph:ph)
        drawPropellers(c,g:g,pw:pw,ph:ph)
        drawWords(c,cloth:cloth,pw:pw,ph:ph)
    }
    private func drawRunway(_ c: CGContext, flight: CGFloat) {
        let w = bounds.width,h = bounds.height,width: CGFloat = 65
        c.saveGState();c.translateBy(x:w*0.5,y:h*0.82)
        c.setFillColor(UIColor(red:226/255,green:227/255,blue:221/255,alpha:1).cgColor)
        c.fill(CGRect(x:-width/2,y:-h*0.87,width:width,height:h*1.2))
        c.setStrokeColor(Self.paper.cgColor);c.setLineWidth(2)
        for x in [-width/2+4,width/2-4] { c.move(to:CGPoint(x:x,y:-h));c.addLine(to:CGPoint(x:x,y:h)) };c.strokePath()
        c.setLineWidth(3);c.setLineDash(phase:-flight*flight*h*0.6,lengths:[19,22])
        c.move(to:CGPoint(x:0,y:-h));c.addLine(to:CGPoint(x:0,y:h));c.strokePath();c.setLineDash(phase:0,lengths:[])
        c.setFillColor(Self.paper.cgColor)
        for j in -2...2 where j != 0 { c.fill(CGRect(x:CGFloat(j)*10-2,y:55,width:4,height:29)) }
        c.restoreGState()
    }
    private func drawAirframe(_ c: CGContext, g: Plane, pw: CGFloat, ph: CGFloat) {
        guard let airframe else { return }
        // Sixteen textured strips preserve perspective foreshortening as the nose pitches up.
        for row in 0..<16 {
            let v0 = CGFloat(row)/16,v1 = CGFloat(row+1)/16
            let uv = [CGPoint(x:0,y:v0*ph),CGPoint(x:pw,y:v0*ph),CGPoint(x:pw,y:v1*ph),CGPoint(x:0,y:v1*ph)]
            let xy = uv.map { project(g,pw,ph,$0.x-pw/2,$0.y-ph/2) }
            for indices in [[0,1,2],[0,2,3]] {
                let a = uv[indices[0]],b = uv[indices[1]],d = uv[indices[2]]
                let p = xy[indices[0]],q = xy[indices[1]],r = xy[indices[2]]
                let sx = b.x-a.x,sy = b.y-a.y,tx = d.x-a.x,ty = d.y-a.y,det = sx*ty-sy*tx
                let m0 = ((q.x-p.x)*ty-(r.x-p.x)*sy)/det,m1 = ((q.y-p.y)*ty-(r.y-p.y)*sy)/det
                let m2 = ((r.x-p.x)*sx-(q.x-p.x)*tx)/det,m3 = ((r.y-p.y)*sx-(q.y-p.y)*tx)/det
                let centre = CGPoint(x:(p.x+q.x+r.x)/3,y:(p.y+q.y+r.y)/3)
                func expanded(_ point: CGPoint) -> CGPoint {
                    let dx = point.x-centre.x,dy = point.y-centre.y,length = max(0.001,hypot(dx,dy))
                    return CGPoint(x:point.x+dx*0.35/length,y:point.y+dy*0.35/length)
                }
                c.saveGState();c.move(to:expanded(p));c.addLine(to:expanded(q));c.addLine(to:expanded(r));c.closePath();c.clip()
                c.concatenate(CGAffineTransform(a:m0,b:m1,c:m2,d:m3,tx:p.x-m0*a.x-m2*a.y,ty:p.y-m1*a.x-m3*a.y))
                airframe.draw(in:CGRect(x:0,y:0,width:pw,height:ph));c.restoreGState()
            }
        }
    }
    private func drawPropellers(_ c: CGContext, g: Plane, pw: CGFloat, ph: CGFloat) {
        let radius = pw*0.069,halfWidth = pw*0.006
        for side: CGFloat in [-1,1] {
            let elapsed = max(0,seconds-(side<0 ? 0.08:0.45)),starting = min(elapsed,1.5),running = max(0,elapsed-1.5)
            let rotation = 2 * .pi*(starting*0.12+starting*starting*1.8+running*5.52+running*running*0.65)
            let x = side*pw*0.1254,y = -ph*0.294
            for ghost in (0...2).reversed() {
                let phase = rotation+side*0.6-CGFloat(ghost)*0.18
                c.saveGState();c.setAlpha(ghost == 0 ? 0.95:0.13)
                for blade in 0..<3 {
                    let angle = phase+CGFloat(blade)*2 * .pi/3
                    func point(_ r: CGFloat, _ width: CGFloat) -> CGPoint {
                        project(g,pw,ph,x+cos(angle)*r-sin(angle)*width,y,sin(angle)*r+cos(angle)*width)
                    }
                    c.setFillColor(Self.ink.cgColor);c.move(to:point(radius*0.08,-halfWidth*0.6))
                    c.addLine(to:point(radius*0.86,-halfWidth));c.addLine(to:point(radius,0))
                    c.addLine(to:point(radius*0.86,halfWidth));c.addLine(to:point(radius*0.08,halfWidth*0.6));c.closePath();c.fillPath()
                    c.setStrokeColor(Self.ivory.cgColor);c.setLineWidth(1.2)
                    c.move(to:point(radius*0.88,0));c.addLine(to:point(radius*0.98,0));c.strokePath()
                };c.restoreGState()
            }
            let centre = project(g,pw,ph,x,y),r = pw*0.009
            c.setFillColor(Self.ivory.cgColor);c.fillEllipse(in:CGRect(x:centre.x-r,y:centre.y-r,width:r*2,height:r*2))
        }
    }
    private func drawWords(_ c: CGContext, cloth: UIBezierPath, pw: CGFloat, ph: CGFloat) {
        c.saveGState();let outside = UIBezierPath(rect:bounds);outside.append(cloth)
        outside.usesEvenOddFillRule = true;outside.addClip()
        func word(_ text: String, origin: CGPoint, age: CGFloat, side: CGFloat, starting: Bool) {
            guard age>0,age<1 else { return }
            let x = origin.x+side*age*(starting ? 42:8),y = origin.y+age*(starting ? -30:68)
            c.saveGState();c.translateBy(x:x,y:y);c.rotate(by:side*(starting ? -0.10-age*0.06:-0.08+age*0.10))
            c.setAlpha(0.82*(starting ? pow(sin(.pi*age),0.65):smooth(age/0.13)))
            let attributes: [NSAttributedString.Key:Any] = [.font:UIFont.italicSystemFont(ofSize:mix(12,14,age)),.foregroundColor:Self.ink,.kern:0.25]
            let size = (text as NSString).size(withAttributes:attributes)
            (text as NSString).draw(at:CGPoint(x:-size.width/2,y:-size.height/2),withAttributes:attributes);c.restoreGState()
        }
        if seconds<startup {
            let starters: [(CGFloat,CGFloat,String,CGFloat)] = [(0.12,-1,"brr…",0.55),(0.48,1,"brr…",0.55),(0.82,-1,"brrrm…",0.62),(1.03,1,"brrrm…",0.47)]
            for (birth,side,text,life) in starters {
                word(text,origin:project(geometry(0),pw,ph,side*pw*0.1254,-ph*0.294),age:(seconds-birth)/life,side:side,starting:true)
            }
        }
        for (index,flightBirth) in [CGFloat(0.02),0.13,0.24,0.35,0.46,0.57,0.68].enumerated() {
            let side: CGFloat = index%2 == 0 ? -1:1
            let origin = project(geometry(flightBirth),pw,ph,side*pw*0.1254,-ph*0.275)
            word("wroom",origin:origin,age:(seconds-startup-flightBirth*takeoff)/1.05,side:side,starting:false)
        }
        c.restoreGState()
    }
}
