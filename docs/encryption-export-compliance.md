# Encryption declaration for App Store Connect

Reviewed 2026-10-25 against v0.5 source `62982bb1a7b78bf289decfc8284874e1ba57d23f`
and its identical beta merge tree at `8d69179180f5f549d012ec11614e98c180e63080`.
The owner requests that the next build carry its encryption statement so repeated
manual App Store Connect selections are unnecessary when the app qualifies.

## Existing declaration

The maintained app already declares this real Boolean in both platform inputs:

```xml
<key>ITSAppUsesNonExemptEncryption</key><false/>
```

- [Mac host Info.plist](../NativeFoundation/Resources/Info.plist)
- [iOS host Info.plist](../NativeFoundation/Resources/Info-iOS.plist)

The project uses the Mac plist by default and selects the iOS plist for iPhone
SDKs. Both apply to Release as well as the local configurations. The Siri Intents
extension is part of the iOS host; it is not a separately submitted app. Its
current source uses native system facilities and adds no independent cryptography
implementation. No export compliance code is configured.

[Apple's key documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption)
specifies `NO` when the app, including linked third-party code, uses no encryption
or only exempt encryption. This declaration does **not** mean network traffic or
credentials are unprotected. It describes the absence of non-exempt encryption.
An Apple-issued compliance code is for cases requiring reviewed documentation;
do not invent one or add an empty code.

Apple states that [providing encryption settings in Info.plist](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds)
eliminates repeated submission questions for an app exempt from documentation.
That expected submission behavior is distinct from observing an uploaded build's
actual App Store Connect status.

## Technical basis for the existing value

The reviewed current source uses Apple-provided cryptographic facilities:

- `URLSession` and native media delivery provide network transport. There is no
  app-provided TLS implementation or custom certificate-validation bypass in the
  reviewed transport paths.
- `Security` framework Keychain operations store the nonsynchronizing session.
  macOS uses Data Protection Keychain; legacy credential lookup is not introduced.
- `CryptoKit` SHA-256 supports scoped storage identifiers and file integrity.
  The app does not implement its own cipher or key-exchange algorithm.

The project links the pinned `JellyfinAPI` package product. Its selected graph uses
`Get`/`URLSession` and `NIOTransportServices`, whose TLS facilities use Apple's
`Network`/`Security` frameworks. The seven committed package pins were compared
with the existing cached checkouts. There is no `NIOSSL`, OpenSSL or Swift Crypto
package in this graph. SwiftNIO's separate `NIOWebSocket`/`CNIOSHA1` targets are not
dependencies of the selected product graph; the SDK websocket uses URLSession.
No general claim about every target in a downloaded package is implied.

These source/configuration observations support retaining `false` under
[Apple's operating-system encryption guidance](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption).
Reassess the declaration when new providers, authentication, cryptographic
libraries or transport features change what the app ships. A dependency's name
or a previously accepted upload alone is not sufficient evidence.

## Verification and release follow-through

Static plist parsing confirms the two host values are Boolean `false`, not strings.
The existing [Release verifier](../scripts/verify-release.py) already requires
`info["ITSAppUsesNonExemptEncryption"] is False` on each actual Release host bundle.
The retained canonical unsigned iOS and Mac 0.5.0 (217) outputs were inspected
read-only and both contain the value. This is prior-artifact evidence, not a new
0.6 archive, signed validation or Apple processing result.

For the next integrated candidate, run normal Release/shipping verification on
the exact produced iOS and Mac app bundles and record the declaration alongside
source, version/build and artifact identity. No normal production-session app
launch is necessary for this metadata check. Preserve the existing assertion.
Then record actual upload processing and export-compliance status separately.
If App Store Connect still asks questions, identify the actual uploaded artifact
before diagnosing why; this review does not establish the cause of a past prompt.

No new metadata or runtime change is necessary for the current host declaration.
This review did not submit an Apple questionnaire, start a Cloud build, install an
app, or establish TestFlight availability. Apple's
[export-compliance guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
also notes that documentation exemptions do not automatically eliminate every
applicable government export/import or reporting obligation.
