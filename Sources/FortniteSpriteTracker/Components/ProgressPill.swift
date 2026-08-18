import SwiftUI

struct ProgressPill: View {
    let title: String
    let value: Int
    let total: Int
    let symbol: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("\(value) / \(total)")
                    .font(.subheadline.monospacedDigit().weight(.heavy))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.07)))
    }
}
