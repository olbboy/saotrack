import SwiftUI

/// Seek waveform: peak bars, played-portion tint, playhead, and the A–B
/// loop region overlay. Click or drag anywhere to scrub; the seek is
/// committed on release so the engine restarts its nodes only once.
struct WaveformView: View {
    let samples: [Float]
    let duration: TimeInterval
    let currentTime: TimeInterval
    let loopStart: TimeInterval?
    let loopEnd: TimeInterval?
    let isLoopEnabled: Bool
    let onSeek: (TimeInterval) -> Void

    @State private var dragTime: TimeInterval?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                guard !samples.isEmpty, duration > 0, size.width > 0 else { return }

                let columnWidth: CGFloat = 3
                let barWidth: CGFloat = 2
                let columns = max(1, Int(size.width / columnWidth))
                let midY = size.height / 2
                let displayTime = dragTime ?? currentTime
                let playX = size.width * CGFloat(min(1, max(0, displayTime / duration)))

                // Loop region backdrop + boundary markers.
                if let start = loopStart, let end = loopEnd, end > start {
                    let x0 = size.width * CGFloat(start / duration)
                    let x1 = size.width * CGFloat(end / duration)
                    let region = CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)
                    context.fill(
                        Path(region),
                        with: .color(.yellow.opacity(isLoopEnabled ? 0.16 : 0.07)))
                    for x in [x0, x1] {
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: 0))
                        line.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(line, with: .color(.yellow.opacity(0.8)), lineWidth: 1)
                    }
                }

                for column in 0..<columns {
                    let startIndex = column * samples.count / columns
                    let endIndex = max(startIndex + 1, (column + 1) * samples.count / columns)
                    let amplitude = CGFloat(samples[startIndex..<min(endIndex, samples.count)].max() ?? 0)
                    let barHeight = max(2, amplitude * size.height * 0.92)
                    let x = CGFloat(column) * columnWidth
                    let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
                    let played = x <= playX
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(played ? Color.accentColor : Color.secondary.opacity(0.35)))
                }

                var playhead = Path()
                playhead.move(to: CGPoint(x: playX, y: 0))
                playhead.addLine(to: CGPoint(x: playX, y: size.height))
                context.stroke(playhead, with: .color(.primary.opacity(0.7)), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragTime = time(atX: value.location.x, width: width)
                    }
                    .onEnded { value in
                        let target = time(atX: value.location.x, width: width)
                        dragTime = nil
                        onSeek(target)
                    }
            )
        }
        .help("Click or drag to seek")
    }

    private func time(atX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0, duration > 0 else { return 0 }
        let fraction = min(1, max(0, x / width))
        return TimeInterval(fraction) * duration
    }
}
