import AppKit
import SwiftUI

/// Visual phase of the floating dictation indicator.
enum IndicatorState: Equatable {
    /// Holding right ⌘: live waveform bars driven by the mic level meter.
    case listening
    /// Released, Parakeet running: shimmering wave, no live level.
    case transcribing
    /// LLM cleanup pass running: same wave, distinct tint.
    case cleaning
}

/// Observable bridge between the controller (level polling, state changes)
/// and the SwiftUI capsule content.
@MainActor
final class IndicatorModel: ObservableObject {
    static let barCount = 14

    @Published var state: IndicatorState = .listening
    /// Per-bar heights (points) while listening, recomputed each poll tick.
    @Published var bars: [CGFloat] = IndicatorModel.idleBars
    /// Snapshot of the system Reduce Motion setting, taken at show time.
    @Published var reduceMotion = false

    static var idleBars: [CGFloat] {
        (0..<barCount).map { envelope($0) * 5 + 3 }
    }

    /// 0…1 weighting that makes center bars taller than edge bars.
    static func envelope(_ index: Int) -> CGFloat {
        let mid = CGFloat(barCount - 1) / 2
        let distance = abs(CGFloat(index) - mid) / mid
        return 1 - 0.72 * pow(distance, 1.4)
    }

    /// Feed one polled mic level (raw peak, 0…1-ish) into the bar heights.
    func applyLevel(_ raw: Float) {
        // Raw speech peaks hover well below 1.0; lift them into a usable
        // 0…1 range with a soft knee so quiet speech still dances.
        let norm = CGFloat(min(1, pow(Double(max(0, raw)) * 4.5, 0.6)))
        let jitterFloor: CGFloat = reduceMotion ? 0.75 : 0.35
        bars = (0..<Self.barCount).map { i in
            let jitter = CGFloat.random(in: jitterFloor...1)
            return Self.envelope(i) * (3 + norm * 26 * jitter) + 3
        }
    }
}

/// The capsule content. Label-free: a red dot + live bars while listening,
/// a shimmering wave while transcribing (white) or cleaning (mint).
private struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
            // Darken the material so the pill reads on light wallpapers too.
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.38))
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            content
        }
        .frame(width: 220, height: 48)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .listening:
            HStack(spacing: 9) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                LiveBarsView(model: model)
            }
        case .transcribing:
            PulsingBarsView(tint: .white.opacity(0.9), reduceMotion: model.reduceMotion)
                .id(IndicatorState.transcribing)
        case .cleaning:
            PulsingBarsView(tint: .mint, reduceMotion: model.reduceMotion)
                .id(IndicatorState.cleaning)
        }
    }
}

/// Live waveform: heights come straight from the model's polled bars.
private struct LiveBarsView: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<IndicatorModel.barCount, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 3.5, height: model.bars[i])
            }
        }
        .frame(height: 34)
        .animation(
            model.reduceMotion ? nil : .easeOut(duration: 0.09),
            value: model.bars)
    }
}

/// Post-release wave: a traveling shimmer across static bar heights. With
/// Reduce Motion on, the bars just sit at their tall height, no animation.
private struct PulsingBarsView: View {
    let tint: Color
    let reduceMotion: Bool
    @State private var pulsing = false

    private static let count = IndicatorModel.barCount

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.count, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: 3.5, height: height(i))
                    .opacity(pulsing ? 1 : 0.45)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.55)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.05),
                        value: pulsing)
            }
        }
        .frame(height: 34)
        .onAppear {
            // With Reduce Motion the .animation above is nil, so this just
            // snaps the bars to fully lit; otherwise it starts the shimmer.
            pulsing = true
        }
    }

    private func height(_ i: Int) -> CGFloat {
        IndicatorModel.envelope(i) * 12 + 5
    }
}

/// Owns the floating, non-activating HUD panel shown during dictation.
/// Focus discipline is the whole point: `.nonactivatingPanel` + never making
/// the panel key means the paste still lands in the app being dictated into.
@MainActor
final class IndicatorController: NSObject {
    private let model = IndicatorModel()
    private var panel: NSPanel?
    /// Non-nil (and polled at ~30 Hz) only while `.listening` is shown.
    private var levelProvider: (@MainActor () -> Float)?
    private var pollTimer: Timer?
    /// Bumped on every show/hide so a stale fade-out completion never
    /// orderOut()s a panel that was re-shown meanwhile.
    private var generation = 0

    private static let size = NSSize(width: 220, height: 48)
    /// Distance from the bottom edge of the screen to the capsule's bottom.
    private static let bottomMargin: CGFloat = 120

    // MARK: - API

    func show(_ state: IndicatorState, levelProvider: (@MainActor () -> Float)?) {
        generation += 1
        let panel = ensurePanel()
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.state = state
        model.bars = IndicatorModel.idleBars
        position(panel)
        // Through the animator with zero duration so any in-flight fade-out
        // (quick tap, immediate re-press) is replaced, not raced.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        self.levelProvider = levelProvider
        if state == .listening, levelProvider != nil {
            startPolling()
        } else {
            stopPolling()
        }
    }

    func transition(to state: IndicatorState) {
        model.state = state
        if state != .listening {
            stopPolling()
            levelProvider = nil
        }
    }

    /// Fades the panel out over ~0.2 s, then orders it out. Safe to call
    /// when already hidden.
    func hide() {
        stopPolling()
        levelProvider = nil
        generation += 1
        guard let panel, panel.isVisible else { return }
        let gen = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }
        // Order out after the fade — unless a newer show() reclaimed the
        // panel in the meantime (generation moved on).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
            }
        }
    }

    // MARK: - Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        // .nonactivatingPanel is CRITICAL: ordering the panel front must not
        // activate Hark or steal key status from the app being dictated into.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: IndicatorView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    /// Bottom-center of the screen containing the mouse pointer (that's where
    /// the user's attention is), re-resolved on every show.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.frame
        panel.setFrame(
            NSRect(
                x: frame.midX - Self.size.width / 2,
                y: frame.minY + Self.bottomMargin,
                width: Self.size.width,
                height: Self.size.height),
            display: false)
    }

    // MARK: - Level polling (~30 Hz, only while .listening is visible)

    private func startPolling() {
        stopPolling()
        // Target/selector (not the block API) for the same reason as the
        // pipeline's AX retry timer: the @Sendable block can't capture this
        // non-Sendable MainActor object. Fires on the main runloop.
        pollTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 30.0, target: self, selector: #selector(pollTick),
            userInfo: nil, repeats: true)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func pollTick() {
        guard let levelProvider else { return }
        model.applyLevel(levelProvider())
    }
}
