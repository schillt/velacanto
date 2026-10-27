# User policy readiness

The owner requested development/security acceptance guidance, a user privacy
policy and terms, and built-in App Store encryption declarations during v0.6
intake on 2026-10-25. The owner supplied publisher **NovoLuxor**, contact
**support@novoluxor.dev**, country **USA**. No corporate suffix or state/venue was
supplied. These facts do not establish incorporation, copyright assignment or
App Store seller-record changes.

## Prepared locally

- [Development acceptance](development-acceptance.md): review and evidence gates
  for development; does not itself certify a candidate.
- Root [SECURITY.md](../SECURITY.md) was created after explicit owner approval of
  the exact preview through the define-security-policy workflow. Inventory found
  no preexisting root/nested policy; the resulting source policy chain resolves
  to that root. No new severity exclusion or accepted-risk waiver was added.
  The owner subsequently authorized committing this policy bundle locally.
  Neither approval authorizes publication or makes the user-policy drafts effective.
- [Privacy draft](privacy-policy.md) and [terms draft](terms-of-use.md): reflect
  current single-account Jellyfin behavior, actual storage/cleanup limits, native
  system surfaces and publisher contact. Future sync/Handoff/providers are not
  represented as implemented. They are not effective legal agreements yet.

## Before user-facing publication or in-app activation

- Confirm publisher identity, applicable jurisdictions, support operations and
  retention practices, and the appropriate legal text for the actual distribution
  regions. Determine whether Apple's standard EULA remains the chosen license;
  this work does not install a custom EULA or modify repository copyright.
- Reconcile existing Chameleon Enterprise copyright/publisher references with
  the owner’s NovoLuxor direction through a separately reviewed branding/legal
  change. Do not treat a name supplied for a policy as proof of copyright transfer
  or update an Apple agreement/seller record automatically.
- Approve final user-policy wording and effective version; remove draft markers
  only then. Choose stable public HTTPS privacy/support/terms URLs and publish
  them through an authorized channel. No hosted website currently follows from
  these local files.
- Add accessible in-app policy links/text, including access before sign-in where
  required. Verify iPhone/iPad/Mac navigation and actual published URLs. Do not
  invent a mandatory consent checkbox for processing that needs another basis;
  new optional cloud features need their own clear controls and disclosures.
- Reconcile App Store Connect privacy answers, SDK behavior/privacy manifests,
  server/support processing and the final app's behavior. An empty collected-data
  manifest is not a blanket no-data-processing statement.
- Verify the existing export declaration on the actual final Release artifacts
  and the upload's compliance status. Do not claim prompts resolved for an
  unobserved future upload or change an exemption when cryptography changes.

## Current source evidence

Reviewed baseline beta `8d69179180f5f549d012ec11614e98c180e63080`, identical tree
to corrected v0.5 `62982bb`. Evidence includes FoundationApp/Library/Credentials,
PlaybackPreferences, Downloads/storage, Settings/Journal, PrivacyInfo.xcprivacy,
LICENSE, and existing pin/queue/sign-out/playback-URL privacy records. Those
records distinguish intended controls and current acceptance limits.

Current Apple references checked on 2026-10-25:

- [App Review Guidelines, privacy](https://developer.apple.com/app-store/review/guidelines/#privacy): accessible privacy policy and accurate retention/sharing/choice disclosures.
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/): evaluate actual app and third-party data practices when answering App Store questions.
- [Custom license agreement guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement): Apple's standard EULA applies unless a custom agreement is provided.
- [Apple standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/): retain the applicable licensing and mandatory-rights framework rather than silently replacing it.

No legal compliance certification, privacy audit pass, public legal publication,
Apple submission, automatic-delivery change or new analytics service is claimed.
