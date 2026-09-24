import SwiftUI

#if os(iOS)
    import MediaPlayer

    /// Native output-volume interaction stays inside MPVolumeView, including route limitations.
    struct FoundationSystemVolumeView: UIViewRepresentable {
        func makeUIView(context: Context) -> MPVolumeView {
            let view = MPVolumeView(frame: .zero)
            view.showsVolumeSlider = true
            view.tintColor = .white
            return view
        }

        func updateUIView(_ uiView: MPVolumeView, context: Context) {}
    }
#endif
