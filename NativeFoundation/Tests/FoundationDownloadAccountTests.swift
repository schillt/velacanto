import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationDownloadAccountTests: XCTestCase {
    func testResidualDownloadsPreventNewSignInRequest() async {
        var requests = 0
        do {
            _ = try await FoundationSignInPolicy.authenticate(
                clearPins: { true }, clearPlaybackSessions: { true }, clearDownloads: { false },
                signIn: {
                    requests += 1
                    throw CancellationError()
                })
            XCTFail("Residual account data must prevent a new sign-in")
        } catch {
            XCTAssertTrue(error is FoundationDownloadAccountError)
        }
        XCTAssertEqual(requests, 0)
    }

    func testDownloadCleanupPrecedesAuthentication() async {
        var steps: [String] = []
        do {
            _ = try await FoundationSignInPolicy.authenticate(
                clearPins: {
                    steps.append("pins")
                    return true
                },
                clearPlaybackSessions: {
                    steps.append("session")
                    return true
                },
                clearDownloads: {
                    steps.append("downloads")
                    return true
                },
                signIn: {
                    steps.append("authenticate")
                    throw CancellationError()
                })
        } catch {}
        XCTAssertEqual(steps, ["pins", "session", "downloads", "authenticate"])
    }
}
