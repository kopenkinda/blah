import AppKit
import SwiftUI

@MainActor
final class RecordingOverlay {
    private let panel: NSPanel
    private weak var controller: DictationController?
    private var displayedNotice: String?

    init(controller: DictationController) {
        self.controller = controller
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 36, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
    }

    func show() {
        guard let controller else { return }
        // Keep the orb on the same display throughout recording and processing.
        let screen = (panel.isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let host: NSHostingView<RecordingIndicator>
        if let existing = panel.contentView as? NSHostingView<RecordingIndicator>,
           displayedNotice == controller.overlayNotice {
            host = existing
        } else {
            host = NSHostingView(rootView: RecordingIndicator(controller: controller))
            panel.contentView = host
            displayedNotice = controller.overlayNotice
        }
        let size = host.fittingSize
        if let screen {
            let bounds = screen.visibleFrame.insetBy(dx: 16, dy: 16)
            let position = controller.preferences.orbPosition
            panel.setFrame(NSRect(
                x: bounds.minX + max(0, bounds.width - size.width) * CGFloat(position.column) / 2,
                y: bounds.minY + max(0, bounds.height - size.height) * CGFloat(2 - position.row) / 2,
                width: size.width, height: size.height
            ), display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        // Stop the animation schedule while the app is idle.
        panel.contentView = nil
    }
}

private struct RecordingIndicator: View {
    var controller: DictationController

    private var alignment: HorizontalAlignment {
        switch controller.preferences.orbPosition.column {
        case 0: .leading
        case 2: .trailing
        default: .center
        }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            RecordingOrb(controller: controller)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .glassEffect(.regular, in: Capsule())
                .padding(4)
            // Temporary diagnostic text while we refine dictation feedback.
            if let notice = controller.overlayNotice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(width: 280, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .fixedSize()
    }
}

private struct RecordingOrb: View {
    var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    private var recording: Bool { controller.captureVisible || (controller.previewingOrb && controller.stage == nil) }
    private var showingNotice: Bool { controller.overlayNotice != nil }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 1.7 : timeline.date.timeIntervalSince(started)
            let level = reduceMotion ? 0 : controller.previewingOrb
                ? 0.2 + 0.15 * sin(time * 4) : Double(controller.level)
            ParticleSphere(time: time, level: level, processing: recording || showingNotice ? 0 : 1,
                           notice: showingNotice, complete: controller.stage == "Pasting")
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: level)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: recording)
                .overlay {
                    if showingNotice {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
        }
        .frame(width: 36, height: 36)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controller.previewingOrb ? "Dictation indicator preview" : showingNotice
                             ? controller.notice ?? "Notice" : controller.status)
    }
}

// Native adaptation of VoiceOrbs' MIT-licensed Particles Orb by Alexis Munoz.
// Fewer, smaller dots preserve the individual particles at 36 points.
private struct ParticleSphere: View, @MainActor Animatable {
    var time: Double
    var level: Double
    var processing: Double
    var notice: Bool
    var complete: Bool

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(level, processing) }
        set { level = newValue.first; processing = newValue.second }
    }

    private struct Point {
        let x: Double
        let y: Double
        let z: Double
        let phase: Double
        let tone: Double
    }

    private static let points: [Point] = (0..<200).map { index in
        let i = Double(index)
        let y = 1 - i / 199 * 2
        let radius = sqrt(max(0, 1 - y * y))
        let theta = Double.pi * (3 - sqrt(5)) * i
        return Point(x: cos(theta) * radius, y: y, z: sin(theta) * radius,
                     phase: (i * 0.61803398875).truncatingRemainder(dividingBy: 1) * .pi * 2,
                     tone: (i * 0.5436890126).truncatingRemainder(dividingBy: 1))
    }

    var body: some View {
        Canvas { context, size in
            let voice = min(1, max(0, level)) * (1 - processing)
            let angle = time * 0.65
            let cosY = cos(angle), sinY = sin(angle)
            let cosX = cos(0.32), sinX = sin(0.32)
            let contraction = processing * (0.22 + 0.12 * sin(time * 2.6 + 1))
            let radius = 12.0 * (1 + 0.0125 * sin(time * 1.1) + voice * 0.16 - contraction)
            // The maximum ripple and dot radius stay within the 36-point canvas.
            for point in Self.points {
                let x = point.x * cosY - point.z * sinY
                let z = point.x * sinY + point.z * cosY
                let y = point.y * cosX - z * sinX
                let depth = (point.y * sinX + z * cosX + 1) / 2
                let perspective = 0.65 + depth * 0.45
                let ripple = (1 - processing) * (0.045 + voice * 0.24)
                    * sin(point.y * 4.5 - time * 6.5)
                let pulse = processing * 0.16 * (0.5 + 0.5 * sin(point.phase + time * 3.1))
                let distance = radius * (1 + ripple - pulse) * perspective
                let dot = 0.25 + depth * 0.43
                let rect = CGRect(x: size.width / 2 + x * distance - dot,
                                  y: size.height / 2 + y * distance - dot,
                                  width: dot * 2, height: dot * 2)
                let tone = point.tone
                let color: Color
                if notice {
                    color = Color(red: 1, green: 0.55 + tone * 0.25, blue: 0.2)
                } else if complete {
                    color = Color(red: 0.35, green: 0.9, blue: 0.7 + tone * 0.25)
                } else {
                    color = Color(red: (240 - 111 * tone) / 255,
                                  green: (171 - 31 * tone) / 255,
                                  blue: (252 - 4 * tone) / 255)
                }
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.16 + depth * depth * 0.84)))
            }
        }
    }
}
