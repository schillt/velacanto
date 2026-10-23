import Intents

/// Siri owns speech input. The extension never accesses an account or creates a player.
final class IntentHandler: INExtension, INPlayMediaIntentHandling {
    override func handler(for intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? self : nil
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        // iOS 14+ performs real resolution in the containing app's handler. If the
        // system chooses this legacy extension path, report this unavailable path honestly.
        completion([.unsupported(forReason: .serviceUnavailable)])
    }

    func handle(
        intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil))
    }
}
