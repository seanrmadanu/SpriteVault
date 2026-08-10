import SwiftUI

struct AnimatedBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.07, green: 0.06, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)

            ForEach(0..<9, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(i.isMultiple(of: 2) ? 0.055 : 0.025))
                    .frame(width: CGFloat(80 + i * 31), height: CGFloat(80 + i * 31))
                    .blur(radius: 18)
                    .offset(
                        x: drift ? CGFloat((i % 3) * 170 - 240) : CGFloat((i % 4) * 130 - 280),
                        y: drift ? CGFloat((i % 4) * 150 - 220) : CGFloat((i % 3) * 190 - 250)
                    )
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) {
                drift.toggle()
            }
        }
    }
}
