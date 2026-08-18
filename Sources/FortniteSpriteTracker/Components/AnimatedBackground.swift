import SwiftUI

/// Kept under the original name so existing views do not change, but the
/// background is intentionally static now. Repeating large radial-gradient
/// animations forced continuous recomposition while the user was scrolling or
/// while Vision was scanning in the background.
struct AnimatedBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(red: 0.055, green: 0.052, blue: 0.085),
                Color(red: 0.075, green: 0.060, blue: 0.115)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
