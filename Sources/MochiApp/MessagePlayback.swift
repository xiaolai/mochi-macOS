import SwiftUI
import AVFoundation

/// Playback stays with the message it belongs to, including during autoplay.
struct MessagePlayback: View {
    @ObservedObject var app: AppModel
    @ObservedObject var audio: AudioController
    let file: String
    let isUser: Bool
    @State private var fileDuration: Double = 0
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    private var active: Bool { app.playbackFile == file }
    private var length: Double { active ? audio.duration : fileDuration }
    private var position: Double { scrubbing ? scrubPosition : active ? audio.position : 0 }
    private var unavailable: Bool { app.busy && app.turn.activity != .playing }
    var body: some View {
        HStack(spacing:8) {
            Button { app.togglePlayback(file,mochi:!isUser) } label: {
                Image(systemName:active && !audio.paused ? "pause.fill" : "play.fill")
                    .frame(width:26,height:26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active && !audio.paused ? "Pause recording" : active ? "Resume recording" : "Play recording")
            .help(active && !audio.paused ? "Pause" : active ? "Resume" : "Play")
            Slider(value:Binding(get:{ position },set:{ value in
                scrubPosition = value
                app.seekPlayback(file,to:value,mochi:!isUser)
            }),in:0...max(length,0.01),onEditingChanged:{ editing in
                scrubbing = editing
                if editing { scrubPosition = active ? audio.position : 0 }
            })
            .controlSize(.small)
            .accessibilityLabel("Recording position")
            .help("Click or drag to jump within this recording")
            .disabled(length <= 0)
            Text("\(timestamp(position)) / \(timestamp(length))")
                .font(.caption.monospacedDigit()).fixedSize()
                .opacity(0.8)
        }
        .frame(width:280)
        .disabled(unavailable)
        .task(id:file) {
            if let recording = try? AVAudioFile(forReading:app.store.root.appendingPathComponent(file)) {
                fileDuration = Double(recording.length) / recording.processingFormat.sampleRate
            }
        }
    }
    private func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0,seconds.isFinite ? seconds : 0))
        return String(format:"%d:%02d",value / 60,value % 60)
    }
}
