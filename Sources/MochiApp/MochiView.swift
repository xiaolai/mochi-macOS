import SwiftUI
import AppKit

struct MochiView: View {
    var speaking = false
    var thinking = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    static let frames: [[CGImage]] = {
        guard let url = Bundle.module.url(forResource:"mochi",withExtension:"webp"), let image = NSImage(contentsOf:url), let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return [] }
        return [(0,6),(4,5),(6,6)].map { row,count in
            (0..<count).compactMap { cg.cropping(to:CGRect(x:$0*192,y:row*208,width:192,height:208)) }
        }
    }()
    var body: some View {
        TimelineView(.animation(minimumInterval:0.18,paused:reducedMotion)) { context in
            let frames = Self.frames.isEmpty ? [] : Self.frames[speaking ? 1 : thinking ? 2 : 0]
            let index = reducedMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate * 3) % max(1,frames.count)
            if !frames.isEmpty {
                Image(decorative:frames[index],scale:1).resizable().interpolation(.high).scaledToFit()
                    .scaleEffect(speaking && index % 2 == 0 ? 1.025 : 1)
                    .rotationEffect(.degrees(thinking && !reducedMotion ? -4 : 0))
            }
        }.accessibilityLabel("Mochi")
    }
}
