import AVKit
import SwiftUI

#if os(iOS)
    import MediaPlayer
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct PlaybackRoutePicker: View {
    var body: some View {
        #if os(iOS)
            IOSRoutePicker()
        #elseif os(macOS)
            MacOSRoutePicker()
        #endif
    }
}

#if os(iOS)
    private struct IOSRoutePicker: UIViewRepresentable {
        func makeUIView(context: Context) -> AVRoutePickerView {
            let picker = AVRoutePickerView()
            picker.activeTintColor = .systemPink
            picker.tintColor = .secondaryLabel
            return picker
        }

        func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
    }

    struct SystemVolumeControl: UIViewRepresentable {
        func makeUIView(context: Context) -> MPVolumeView {
            let volumeView = MPVolumeView()
            volumeView.showsVolumeSlider = true
            return volumeView
        }

        func updateUIView(_ uiView: MPVolumeView, context: Context) {}

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: MPVolumeView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width else { return nil }
            return CGSize(width: max(0, width), height: 34)
        }
    }
#elseif os(macOS)
    private struct MacOSRoutePicker: NSViewRepresentable {
        func makeNSView(context: Context) -> AVRoutePickerView {
            AVRoutePickerView()
        }

        func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
    }
#endif
