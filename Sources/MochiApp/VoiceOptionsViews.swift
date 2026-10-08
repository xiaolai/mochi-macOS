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
        DisclosureGroup("OpenAI Voice Options",isExpanded:$expanded) {
            VoiceValueSlider(title:"Speech speed",value:$options.speed,range:0.25...1.5,speed:true)
            Text("1× is natural speed. Applies when generating speech; playback speed is separate.").font(.caption).foregroundStyle(.secondary)
            Button("Reset OpenAI Options") { options = OpenAIVoiceOptions() }
        }
    }
}
struct ElevenVoiceOptionsView: View {
    @Binding var options: ElevenVoiceOptions
    var body: some View {
        VoiceValueSlider(title:"Stability",value:$options.stability,range:0...1)
        VoiceValueSlider(title:"Similarity",value:$options.similarity,range:0...1)
        VoiceValueSlider(title:"Style",value:$options.style,range:0...1)
        Toggle("Speaker boost",isOn:$options.speakerBoost)
        Text("Lower stability adds variation. Higher similarity strengthens voice likeness. Style emphasizes the speaker’s delivery; speaker boost improves likeness.").font(.caption).foregroundStyle(.secondary)
    }
}
struct PersonalVoiceOptionsView: View {
    @Binding var options: PersonalVoiceOptions
    @State var expanded = false
    var body: some View {
        DisclosureGroup("ElevenLabs Voice Options",isExpanded:$expanded) {
            Text("Pronunciation example").font(.headline)
            VoiceValueSlider(title:"Speech speed",value:$options.speed,range:0.7...1.2,speed:true)
            ElevenVoiceOptionsView(options:$options.pronunciation)
            Divider()
            Text("Convert to my voice").font(.headline)
            ElevenVoiceOptionsView(options:$options.conversion)
            Text("Conversion keeps the example’s timing. These settings apply to new examples and previews. Regenerate a saved example to change its audio.").font(.caption).foregroundStyle(.secondary)
            Button("Reset ElevenLabs Options") { options = PersonalVoiceOptions() }
        }
    }
}
