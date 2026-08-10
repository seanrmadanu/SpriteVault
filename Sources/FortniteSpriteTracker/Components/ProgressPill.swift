import SwiftUI

struct ProgressPill: View {
    let title: String
    let value: Int
    let total: Int
    let symbol: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: total == 0 ? 0 : CGFloat(value) / CGFloat(total))
                    .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: value)
                Image(systemName: symbol).font(.system(size: 13, weight: .bold))
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text("\(value) / \(total)").font(.title3.monospacedDigit().weight(.heavy))
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
        .scaleEffect(pulse ? 1.015 : 1)
        .onChange(of: value) { _, _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { pulse = true }
            withAnimation(.easeOut(duration: 0.25).delay(0.2)) { pulse = false }
        }
    }
}
