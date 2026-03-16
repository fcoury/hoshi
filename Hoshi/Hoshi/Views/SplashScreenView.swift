import SwiftUI

// MARK: - Splash container (manages splash → main transition)

/// Overlays the splash animation on top of the main app content,
/// then removes it once the animation completes.
struct SplashContainerView: View {
    let style: SplashStyle
    @State private var showSplash = true

    var body: some View {
        ZStack {
            ServerListView()

            if showSplash {
                SplashScreenView(style: style) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showSplash = false
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Splash screen style selector

/// Which splash animation plays on cold launch.
/// Change this single value to swap between the three designs.
enum SplashStyle: String, CaseIterable {
    case terminalBoot    // Variation A — Nord-themed terminal boot sequence
    case neonPulse       // Variation B — Neon cyan glow on black void
    case constellation   // Variation C — Deep-space starfield with warm gold
}

// MARK: - Router view

/// Picks the right splash animation based on the chosen style.
struct SplashScreenView: View {
    let style: SplashStyle
    var onFinished: () -> Void

    var body: some View {
        switch style {
        case .terminalBoot:
            TerminalBootSplash(onFinished: onFinished)
        case .neonPulse:
            NeonPulseSplash(onFinished: onFinished)
        case .constellation:
            ConstellationSplash(onFinished: onFinished)
        }
    }
}

// MARK: - Variation A: Terminal Boot Sequence
//
// Nord theme colors, kanji fades in with glow, "hoshi" typed out
// character-by-character with a blinking block cursor. 2.0s total.

private struct TerminalBootSplash: View {
    var onFinished: () -> Void

    // Nord palette
    private let bgColor = Color(red: 0x2E / 255.0, green: 0x34 / 255.0, blue: 0x40 / 255.0)
    private let cyanColor = Color(red: 0x88 / 255.0, green: 0xC0 / 255.0, blue: 0xD0 / 255.0)
    private let fgColor = Color(red: 0xD8 / 255.0, green: 0xDE / 255.0, blue: 0xE9 / 255.0)

    // Animation phase state
    @State private var kanjiOpacity: Double = 0
    @State private var kanjiScale: CGFloat = 0.85
    @State private var typedCount: Int = 0
    @State private var showCursor: Bool = false
    @State private var cursorVisible: Bool = true
    @State private var fadeOut: Bool = false

    private let word = Array("hoshi")

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 16) {
                // Kanji with cyan glow
                Text("星")
                    .font(.system(size: 72, weight: .regular, design: .monospaced))
                    .foregroundColor(cyanColor)
                    .shadow(color: cyanColor.opacity(0.6), radius: 20)
                    .shadow(color: cyanColor.opacity(0.3), radius: 40)
                    .opacity(kanjiOpacity)
                    .scaleEffect(kanjiScale)

                // Typed text with cursor
                HStack(spacing: 0) {
                    Text(String(word.prefix(typedCount)))
                        .font(.system(size: 24, weight: .regular, design: .monospaced))
                        .foregroundColor(fgColor)

                    // Block cursor
                    if showCursor {
                        Text("▋")
                            .font(.system(size: 24, weight: .regular, design: .monospaced))
                            .foregroundColor(fgColor)
                            .opacity(cursorVisible ? 1 : 0)
                    }
                }
                .frame(height: 30)
            }
            .opacity(fadeOut ? 0 : 1)
        }
        .onAppear { startAnimation() }
    }

    private func startAnimation() {
        // Phase 1 (0.0–0.5s): kanji fades + scales in
        withAnimation(.easeOut(duration: 0.5)) {
            kanjiOpacity = 1
            kanjiScale = 1.0
        }

        // Phase 2 (0.5–1.2s): type out "hoshi" one character at a time
        showCursor = true
        let charDelay = 0.14 // ~0.7s for 5 chars
        for i in 0..<word.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * charDelay) {
                typedCount = i + 1
            }
        }

        // Phase 3 (1.2–1.5s): cursor blinks twice then disappears
        startCursorBlink(at: 1.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCursor = false
        }

        // Phase 4 (1.5–2.0s): fade out, then signal completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeIn(duration: 0.5)) {
                fadeOut = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            onFinished()
        }
    }

    private func startCursorBlink(at startTime: Double) {
        // Two full blink cycles (on-off-on-off) over 0.3s
        let interval = 0.15
        for i in 0..<4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + startTime + Double(i) * interval) {
                cursorVisible = (i % 2 == 0)
            }
        }
    }
}

// MARK: - Variation B: Neon Pulse
//
// Pure black background, electric cyan + deep blue dual glow on the kanji,
// "HOSHI" with letter-spacing animation and a thin cyan line. 2.2s total.

private struct NeonPulseSplash: View {
    var onFinished: () -> Void

    private let electricCyan = Color(red: 0x00 / 255.0, green: 0xD4 / 255.0, blue: 0xFF / 255.0)
    private let deepBlue = Color(red: 0x00 / 255.0, green: 0x66 / 255.0, blue: 0xFF / 255.0)
    private let textWhite = Color.white.opacity(0.8)

    @State private var kanjiOpacity: Double = 0
    @State private var kanjiScale: CGFloat = 0.7
    @State private var glowOpacity: Double = 0.6
    @State private var textOpacity: Double = 0
    @State private var letterSpacing: CGFloat = 20
    @State private var lineWidth: CGFloat = 0
    @State private var pulseGlow: Bool = false
    @State private var fadeOut: Bool = false
    @State private var exitScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                // Kanji with dual-layer glow
                ZStack {
                    // Outer blue halo
                    Text("星")
                        .font(.system(size: 80, weight: .regular, design: .monospaced))
                        .foregroundColor(deepBlue.opacity(0.2))
                        .blur(radius: 40)

                    // Inner cyan glow
                    Text("星")
                        .font(.system(size: 80, weight: .regular, design: .monospaced))
                        .foregroundColor(electricCyan.opacity(glowOpacity))
                        .blur(radius: 15)

                    // Kanji itself
                    Text("星")
                        .font(.system(size: 80, weight: .regular, design: .monospaced))
                        .foregroundColor(.white)
                }
                .opacity(kanjiOpacity)
                .scaleEffect(kanjiScale)

                // "HOSHI" with tracking + underline
                VStack(spacing: 8) {
                    Text("HOSHI")
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundColor(textWhite)
                        .tracking(letterSpacing)
                        .opacity(textOpacity)

                    // Thin cyan line
                    Rectangle()
                        .fill(electricCyan)
                        .frame(width: lineWidth, height: 1)
                }
            }
            .scaleEffect(exitScale)
            .opacity(fadeOut ? 0 : 1)
        }
        .onAppear { startAnimation() }
    }

    private func startAnimation() {
        // Phase 1 (0.0–0.6s): kanji appears with expanding glow, spring scale
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
            kanjiOpacity = 1
            kanjiScale = 1.0
        }

        // Phase 2 (0.6–0.8s): glow pulses once
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 0.2)) {
                glowOpacity = 1.0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeInOut(duration: 0.2)) {
                glowOpacity = 0.6
            }
        }

        // Phase 3 (0.8–1.3s): text fades in with tracking animation, line draws
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.5)) {
                textOpacity = 1
                letterSpacing = 8
            }
            withAnimation(.easeInOut(duration: 0.5)) {
                lineWidth = 80
            }
        }

        // Phase 4 (1.3–1.8s): subtle continuous glow pulse
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation(.easeInOut(duration: 0.5).repeatCount(2, autoreverses: true)) {
                glowOpacity = 0.9
            }
        }

        // Phase 5 (1.8–2.2s): scale up slightly while fading out
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.4)) {
                exitScale = 1.05
                fadeOut = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            onFinished()
        }
    }
}

// MARK: - Variation C: Constellation
//
// Deep-space navy background, scattered warm-gold star particles connected
// by faint constellation lines to the central kanji. 2.5s total.

private struct StarParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    let size: CGFloat
    let opacity: Double
    let delay: Double
}

private struct ConstellationSplash: View {
    var onFinished: () -> Void

    private let bgColor = Color(red: 0x0A / 255.0, green: 0x0E / 255.0, blue: 0x17 / 255.0)
    private let starColor = Color(red: 0xFF / 255.0, green: 0xE4 / 255.0, blue: 0xB5 / 255.0)
    private let goldAccent = Color(red: 0xC9 / 255.0, green: 0xA9 / 255.0, blue: 0x6E / 255.0)
    private let parchment = Color(red: 0xE8 / 255.0, green: 0xDC / 255.0, blue: 0xC8 / 255.0)

    @State private var stars: [StarParticle] = []
    @State private var starsVisible: Bool = false
    @State private var kanjiOpacity: Double = 0
    @State private var kanjiGlow: Double = 0
    @State private var linesOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var twinklePhase: Bool = false
    @State private var fadeOut: Bool = false
    @State private var driftOffset: CGFloat = 0
    @State private var hasGeneratedStars: Bool = false

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 - 30)

                ZStack {
                    // Star particles
                    ForEach(stars) { star in
                        Circle()
                            .fill(starColor.opacity(star.opacity * (twinklePhase ? 0.7 : 1.0)))
                            .frame(width: star.size, height: star.size)
                            .position(
                                x: star.x + driftOffset * (star.x > center.x ? 1 : -1),
                                y: star.y + driftOffset * (star.y > center.y ? 1 : -1)
                            )
                            .opacity(starsVisible ? 1 : 0)
                            .animation(
                                .easeIn(duration: 0.3).delay(star.delay),
                                value: starsVisible
                            )
                    }

                    // Constellation lines from nearby stars to center
                    Canvas { context, _ in
                        let nearStars = stars.prefix(5)
                        for star in nearStars {
                            var path = Path()
                            let starPos = CGPoint(
                                x: star.x + driftOffset * (star.x > center.x ? 1 : -1),
                                y: star.y + driftOffset * (star.y > center.y ? 1 : -1)
                            )
                            path.move(to: starPos)
                            path.addLine(to: center)
                            context.stroke(
                                path,
                                with: .color(goldAccent.opacity(0.15)),
                                lineWidth: 0.5
                            )
                        }
                    }
                    .opacity(linesOpacity)

                    // Center kanji + text
                    VStack(spacing: 16) {
                        Text("星")
                            .font(.system(size: 72, weight: .regular, design: .monospaced))
                            .foregroundColor(starColor)
                            .shadow(color: starColor.opacity(kanjiGlow * 0.5), radius: 25)
                            .shadow(color: goldAccent.opacity(kanjiGlow * 0.3), radius: 40)
                            .opacity(kanjiOpacity)

                        VStack(spacing: 6) {
                            Text("hoshi")
                                .font(.system(size: 22, weight: .regular, design: .monospaced))
                                .foregroundColor(parchment)

                            Text("mobile terminal")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundColor(parchment.opacity(0.5))
                        }
                        .opacity(textOpacity)
                    }
                    .position(center)
                }
                .onAppear {
                    generateStarsIfNeeded(in: geo.size)
                    startAnimation()
                }
            }
            .opacity(fadeOut ? 0 : 1)
        }
    }

    // Scatter 10 star particles once we know the container size
    private func generateStarsIfNeeded(in size: CGSize) {
        guard !hasGeneratedStars, size.width > 0 else { return }
        hasGeneratedStars = true

        let centerX = size.width / 2
        let centerY = size.height / 2
        var result: [StarParticle] = []
        for i in 0..<10 {
            var x: CGFloat
            var y: CGFloat
            // Keep generating until we're at least 80pt from center
            repeat {
                x = CGFloat.random(in: 30...(size.width - 30))
                y = CGFloat.random(in: 80...(size.height - 80))
            } while hypot(x - centerX, y - centerY) < 80

            result.append(StarParticle(
                x: x, y: y,
                size: CGFloat.random(in: 2...4),
                opacity: Double.random(in: 0.4...0.9),
                delay: Double(i) * 0.03
            ))
        }
        stars = result
    }

    private func startAnimation() {
        // Phase 1 (0.0–0.3s): star dots fade in with staggered timing
        starsVisible = true

        // Phase 2 (0.3–0.8s): kanji fades in with warm glow, constellation lines draw
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeOut(duration: 0.5)) {
                kanjiOpacity = 1
                kanjiGlow = 1
                linesOpacity = 1
            }
        }

        // Phase 3 (0.8–1.3s): stars twinkle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeInOut(duration: 0.5).repeatCount(3, autoreverses: true)) {
                twinklePhase = true
            }
        }

        // Phase 4 (1.3–1.8s): text fades in
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation(.easeOut(duration: 0.5)) {
                textOpacity = 1
            }
        }

        // Phase 5 (1.8–2.5s): stars drift outward, everything fades
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.7)) {
                driftOffset = 15
                fadeOut = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            onFinished()
        }
    }
}
