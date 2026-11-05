import MuseCore
import SwiftUI

/// The keyframe timeline under the plan: ruler 0…duration, CAMERA, one track per character, CUTS; keys as red diamonds,
/// the span between keys as a labelled bar, a red playhead with its time chip (drag anywhere to scrub) and the END chip.
struct CameraTimelineView: View {
    @Environment(\.theme) private var t
    var session: CameraSession
    @Binding var playhead: Double

    private let labelWidth: CGFloat = 110
    private let rulerHeight: CGFloat = 24
    private let rowHeight: CGFloat = 36

    var body: some View {
        let tracks = CameraTimeline.tracks(session)
        let duration = max(0.1, session.durationSec)
        GeometryReader { g in
            let laneW = max(1, g.size.width - labelWidth - 16)
            let x = { (s: Double) -> CGFloat in labelWidth + CGFloat(s / duration) * laneW }
            ZStack(alignment: .topLeading) {
                // Ruler
                let ruler = CameraPathTicks.ruler(duration: duration)
                ForEach(ruler.indices, id: \.self) { i in
                    Rectangle().fill(t.line).frame(width: 1, height: rulerHeight).offset(x: x(ruler[i].t))
                    Text(ruler[i].label).font(t.mono(10.5)).foregroundStyle(t.muted).offset(x: x(ruler[i].t) + 4, y: 4)
                }
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                    lane(track, top: rulerHeight + CGFloat(i) * rowHeight, x: x, laneW: laneW)
                }
                // END chip on the cuts row.
                if let last = tracks.indices.last {
                    chip(CameraTimeline.endLabel(session.durationSec).uppercased(), accent: false)
                        .offset(x: x(duration) - 74, y: rulerHeight + CGFloat(last) * rowHeight + 7)
                }
                // Playhead
                Rectangle().fill(t.accent).frame(width: 2, height: g.size.height).offset(x: x(playhead) - 1)
                chip(CameraTimeline.playheadLabel(playhead).uppercased(), accent: true)
                    .offset(x: x(playhead) + 5, y: g.size.height - 24)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                playhead = CameraTimeline.time(x: Double(v.location.x - labelWidth), width: Double(laneW), duration: duration, fps: session.fps)
            })
        }
        .frame(height: rulerHeight + CGFloat(tracks.count) * rowHeight + 8)
        .background(t.surface)
        .overlay(alignment: .top) { Rectangle().fill(t.line).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline · playhead \(CameraTimeline.playheadLabel(playhead)) of \(CameraText.seconds(session.durationSec))")
        .accessibilityAdjustableAction { dir in
            let step = 1 / max(1, session.fps) * 6
            playhead = min(session.durationSec, max(0, playhead + (dir == .increment ? step : -step)))
        }
    }

    private func lane(_ track: TimelineTrack, top: CGFloat, x: @escaping (Double) -> CGFloat, laneW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Text(track.name).font(t.label).tracking(0.9).foregroundStyle(t.ink).lineLimit(1)
                .frame(width: labelWidth - 14, height: rowHeight, alignment: .leading)
                .offset(x: 14)
            Rectangle().fill(t.line).frame(width: laneW + 16, height: 1).offset(x: labelWidth, y: rowHeight - 1)
            ForEach(Array(track.spans.enumerated()), id: \.offset) { _, span in
                let w = max(2, x(span.end) - x(span.start))
                Text(span.label).font(t.mono(10.5, .medium)).lineLimit(1)
                    .foregroundStyle(span.accent ? t.accent : span.muted ? t.muted : t.ink)
                    .padding(.leading, 10)
                    .frame(width: w, height: 22, alignment: .leading)
                    .background(span.accent ? t.accent.opacity(0.14) : t.surface2)
                    .clipped()
                    .offset(x: x(span.start), y: 7)
            }
            ForEach(Array(track.keys.enumerated()), id: \.offset) { _, k in
                if track.id == "cuts" {
                    Rectangle().fill(t.ink).frame(width: 2, height: 20).offset(x: x(k) - 1, y: 8)
                } else {
                    Rectangle().fill(t.accent).frame(width: 9, height: 9).rotationEffect(.degrees(45)).offset(x: x(k) - 4.5, y: 13.5)
                }
            }
        }
        .offset(y: top)
    }

    private func chip(_ text: String, accent: Bool) -> some View {
        Text(text).font(t.mono(10.5, .medium)).tracking(0.6)
            .foregroundStyle(accent ? t.accent : t.ink)
            .padding(.horizontal, 8).frame(height: 20)
            .background(t.surface)
            .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 4).strokeBorder(accent ? t.accent : t.line, lineWidth: 1))
            .fixedSize()
    }
}
