import SwiftUI
import MochiCore

struct VoiceValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var speed = false
    var body: some View {
        HStack {
            Text(title).frame(width:110,alignment:.leading)
            Slider(value:$value,in:range,step:0.05).accessibilityLabel(title)
            Text(speed ? String(format:"%.2f×",value) : String(format:"%.2f",value))
                .monospacedDigit().frame(width:48,alignment:.trailing)
        }
    }
}
struct OpenAIVoiceOptionsView: View {
    @Binding var options: OpenAIVoiceOptions
    @State var expanded = false
    var body: some View {
        DisclosureGroup("Voice Options",isExpanded:$expanded) {
            VoiceValueSlider(title:"Speech speed",value:$options.speed,range:0.25...1.5,speed:true)
            Text("1× is natural speed. Applies when generating speech; playback speed is separate.").font(.caption).foregroundStyle(.secondary)
            Button("Reset Voice Options") { options = OpenAIVoiceOptions() }
        }
    }
}
