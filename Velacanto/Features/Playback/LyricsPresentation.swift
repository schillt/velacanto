import SwiftUI

struct LyricsUnavailableControl: View {
    var body: some View {
        Image(systemName: "quote.bubble")
            .frame(width: 44, height: 44)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Lyrics unavailable")
            .accessibilityAddTraits(.isStaticText)
    }
}
