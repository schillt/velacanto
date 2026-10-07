import AVKit
import SwiftUI

// Routing remains owned by the platform; no session changes or discovery tasks.
#if os(iOS)
    struct FoundationAirPlayPicker: UIViewRepresentable {
        let player: FoundationPlayer

        func makeUIView(context: Context) -> AVRoutePickerView {
            let view = AVRoutePickerView()
            view.prioritizesVideoDevices = false
            view.tintColor = .white
            view.accessibilityLabel = "AirPlay"
            return view
        }

        func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
    }
#elseif os(macOS)
    struct FoundationAirPlayPicker: NSViewRepresentable {
        let player: FoundationPlayer

        func makeNSView(context: Context) -> AVRoutePickerView {
            let view = AVRoutePickerView()
            view.player = player.nativePlayer
            view.setRoutePickerButtonColor(.white, for: .normal)
            view.setAccessibilityLabel("AirPlay")
            return view
        }

        func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
            if nsView.player !== player.nativePlayer {
                nsView.player = player.nativePlayer
            }
        }
    }
#endif
