import SwiftUI

struct AnimatedBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.07, green: 0.06, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)

            glow(
                color: .purple,
                size: 520,
                from: CGSize(width: -330, height: -250),
                to: CGSize(width: -180, height: -120)
            )
            glow(
                color: .indigo,
                size: 460,
                from: CGSize(width: 360, height: 250),
                to: CGSize(width: 220, height: 140)
            )
            glow(
                color: .blue,
                size: 340,
                from: CGSize(width: 270, height: -310),
                to: CGSize(width: 390, height: -170)
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
                drift.toggle()
            }
        }
    }

    private func glow(color: Color, size: CGFloat, from: CGSize, to: CGSize) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.13), color.opacity(0.035), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .offset(drift ? to : from)
    }
}
