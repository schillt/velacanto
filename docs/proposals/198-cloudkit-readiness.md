# #198 CloudKit capability decision packet

Review-only proposal from exact integrated base
`90f8602f4fb95dff884c8a254753f99b6d539be2`. Prepared 2026-10-27 UTC.
The runtime remains default OFF and unconfigured. Nothing here registers a
container, changes Apple settings/profiles, changes a legal agreement, starts a
native build or enables a user's sync consent.

## Concrete source proposal

Proposed container: **`iCloud.com.chameleonenterprise.velacanto`** under existing
team **`B9X8T5LT8Q`**. Its registration, availability and associations are **not
verified**. The same reviewed container must serve authorized iPhone/iPad/Mac apps
within the same CloudKit environment. Do not derive the container from a local
bundle override or silently use a default container.

[Native configuration patch](198-cloudkit-native-config.patch) is an unapplied
five-path patch: four new CloudKit plist variants plus two app-target project
configuration lines in the existing project file. It:

- Preserves baseline iOS CarPlay/Siri and Mac sandbox/network/application/Keychain
  entitlements, adding only `com.apple.developer.icloud-services = [CloudKit]` and
  `com.apple.developer.icloud-container-identifiers = [proposed container]`.
- Adds `VelacantoPinSyncContainerIdentifier` with that exact container to proposed
  platform Info variants. This key controls availability, not user consent; fresh
  scoped consent still defaults OFF. An empty Info value is not a safe OFF flag
  with the current code; keeping the key absent is the unconfigured state.
- Selects those variants only for app Debug/Release. UITesting keeps its original
  platform Info/entitlements and absent sync key; no `.uitesting` app-ID/container
  access is requested. Tests compiled under a Debug app host still need controlled
  fixtures and must not enable real sync implicitly.
- Leaves every bundle ID, Keychain access group, deployment version, export
  declaration, Intents extension and existing unrelated Info value unchanged.

The variants are exact copies plus the reviewed keys. Their duplication creates a
maintenance obligation: future common Info/entitlement changes must reach both
variants, or the maintainer must replace them with a verified generation step.
The patch is a concrete configuration candidate, not authorization to apply it.
Do not apply its Info activation before the profile/container gate below.

No App Group entitlement is needed for this implementation: the existing main-app
pin owner alone accesses its local storage; CloudKit associations provide access
to the shared private cloud container across the distinct app identifiers. No
shared local UserDefaults suite, filesystem container, shared Keychain group,
iCloud Documents, ubiquitous key-value store, Push/APNs subscription, remote
notification background mode or Intents CloudKit entitlement is requested. If a
capability UI adds ancillary settings, review those changes explicitly.
[Apple's container model permits multiple apps to use a single container](https://developer.apple.com/icloud/cloudkit/designing/).

## Actual local signing evidence

A private local signing inventory was read from retained
signed219 canonical Mac, local Alpha Mac and iOS artifacts, corroborating
`milestone-validation/release060-install-219/signed-result.json`. It is historical
artifact evidence, not inspection of phone222 or fresh signing acceptance.

| App lane | Concrete signed application ID | Retained profile coverage | Consequence |
| --- | --- | --- | --- |
| Canonical Mac | `B9X8T5LT8Q.com.chameleonenterprise.velacanto` | Same explicit ID | Enable/verify CloudKit association on that existing ID; obtain a profile actually authorizing it. |
| Canonical iOS/iPadOS | `B9X8T5LT8Q.com.chameleonenterprise.velacanto` | Same explicit ID | Same container association and matching platform profile required. |
| Preserved local Mac Alpha | `B9X8T5LT8Q.com.chameleonenterprise.velacanto.siri-validation` | `B9X8T5LT8Q.*` wildcard | Find or register the **exact explicit** `.siri-validation` ID and associate the reviewed container; replace the wildcard profile with the proper explicit capability profile. Keep its data and credential identity. |

None of these retained profiles or signed entitlements contains an iCloud service,
container or environment entitlement. Their packaged Info sync key is absent.
Profile expiration alone does not grant CloudKit permission. The local Alpha
credential group is exactly
`B9X8T5LT8Q.com.chameleonenterprise.velacanto.siri-validation`; canonical Mac's is
`B9X8T5LT8Q.com.chameleonenterprise.velacanto`. Never replace either with the cloud
container name or broaden them to a shared wildcard group. Do not rename/reinstall
apps or move their sandbox data to solve provisioning.

The source's `$(AppIdentifierPrefix)` is preserved. Future signed profiles must
supply the appropriate actual prefix and authorize those unchanged concrete
Keychain groups. Source entitlements alone cannot prove this.
[Apple requires explicit eligible app IDs for iCloud](https://developer.apple.com/library/archive/documentation/ToolsLanguages/Conceptual/DevPortalGuide/CreatingandConfiguringAppIDs/CreatingandConfiguringAppIDs.html).

## Approval and provisioning sequence

1. Review the proposed container, participating app IDs and patch. Before any
   mutation, inspect the authenticated Apple team/IDs/container read-only. A
   similarly named existing container is not permission to adopt unrelated data.
2. After scoped approval, register the container only if absent and authorized;
   enable CloudKit and associate only canonical and exact local Alpha app IDs.
   Preserve unrelated capabilities and the modern Keychain contract.
3. Obtain matching new platform development profiles; later distribution profiles
   are a separate artifact lane. Do not reuse the retained wildcard Alpha profile,
   edit a signed profile, force an entitlement not covered by the profile, use
   `-allowProvisioningUpdates` as an unreviewed external mutation, or start a build
   merely to make Xcode create identifiers automatically.
4. Validate a disposable signed candidate before an owner-used normal launch:
   exact source/Info/bundle ID; strict signature; embedded profile coverage and
   expiration; actual signed iCloud service/container/environment; preserved
   Keychain groups, app sandbox and iOS Siri/CarPlay permissions. Compare profiles
   without publishing device/certificate/profile UUID inventories.
5. Use **Development** on both ends for the first authorized disposable validation.
   Debug/Release is a compiler configuration, not proof of a CloudKit environment.
   Xcode/export signing must supply the correct environment entitlement; the patch
   deliberately does not hard-code one. Native CloudKit selects its environment
   from the signed entitlement. Development and Production do not share records.
   Existing canonical TestFlight30 is unrelated and must remain preserved.
6. Define/review `VelaCantoPinsV1` with one Bytes `payload` field in the private
   database's default zone, record ID `pins-v1-<existing SHA-256 source scope>`.
   Only direct record fetch/CAS is used; no query indexes, public/shared records,
   custom zones, assets or subscriptions are needed. Use synthetic authorized
   library/account references. Read-only console inspection can establish schema;
   first test writes/schema creation still require the approved external-data lane.
7. Run the issue's signed iPhone/iPad/Mac merge/offline/deletion/account/disable
   matrix, including payload inspection and stale callbacks. Source tests cannot
   establish signed-container access or CloudKit account behavior.
8. Production schema deployment and profiles need a separate reviewed step before
   a separately authorized TestFlight/release. TestFlight cannot use Development.
   Do not use shipping/TestFlight as a workaround to test basic capability access.
   All release-milestone and distribution gates still apply.

These steps follow Apple's [iCloud capability setup](https://developer.apple.com/documentation/xcode/configuring-icloud-services),
[signed environment selection](https://developer.apple.com/documentation/cloudkit/ckcontainer),
[production schema deployment](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
and [CloudKit testing guidance](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/TestingYourApp/TestingYourApp.html).

## What can be verified now versus authenticated Apple access

Without asking the owner for already-discoverable facts: source/container flag
absence, exact IDs/team, retained profile/signed entitlement coverage, privacy
manifest contents, patch application/parse validity, preserved unrelated settings
and scoped tests/evidence can be inspected locally. This packet completed those
source/artifact checks. Root reports canonical Mac's 19 pin tests passed in the
100-case selected run; this is coordinator-reported evidence and is not a fresh
run by this worker or a passed CloudKit service gate.

Authenticated Apple Developer/CloudKit Console access is required to establish
actual registration/ownership, explicit local Alpha ID existence, associations,
permitted environments, refreshed profile grants, console schema and account
roles. No matching Apple connector was available in the tool inventory. Those
facts should be inspected in an authorized read-only Apple session when the
serialized UI lane is free, rather than asking the owner to transcribe them.
Creating/enabling associations, issuing profiles, test writes and production
schema deployment are mutations requiring the scoped review above. No automatic
agreement acceptance is authorized. If an Apple account lacks the role needed for
an operation, record the exact blocker rather than treating the container as ready.

## Privacy draft review

[Privacy draft patch](198-privacy-policy-draft.patch) is separate and unapplied.
It retains the draft/not-effective banner. It replaces the blanket “does not
synchronize pins” statement with the configured-build/default-OFF behavior,
minimal data/Apple recipient description, cloud/local retention, explicit deletion
and reset sentinel, iCloud-account changes and backup limits. Credentials remain
non-synchronizing. It does not claim anonymous hashes, end-to-end encryption,
immediate cross-device push, Apple historical erasure or exhaustive acceptance.

The existing PrivacyInfo.xcprivacy has an empty collected-data list, no tracking,
and a UserDefaults reason. Do not automatically translate that into an App Store
“No Data Collected” answer for the activated cloud feature. Review actual signed
behavior, Apple guidance and final disclosures before changing manifest or App
Store privacy answers; no change is applied here. The encryption declaration,
SECURITY.md, publisher identity and effective legal agreements remain untouched.

Before activation, root must reconcile disclosures with the exact integrated
feature set (including separately evolving Handoff/local-library work), approve
wording and retain draft status until legal publication is authorized. There is
no legal certification or new release authorization in this packet.
