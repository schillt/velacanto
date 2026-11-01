# Artist branding local candidate

Artist detail pages keep the shared destination, circular portrait, Favorite control
and direct Pin control. Artist metadata can supply a Logo wordmark instead of the
hero title, with the artist name retained as its accessibility label. Missing or
unreadable optional artwork leaves the text title and existing tint intact.

Backdrop artwork sits behind the portrait and fades into the content tint with the
existing legibility gradients. The iOS portrait has 40 additional points of top
space and 12 points below it. macOS album treatment and shelf underlap are unchanged.

The neutral item model carries optional Logo/Backdrop revision tags and explicit
artwork roles. Jellyfin artist detail hydration uses one cancellable metadata read
per active hero input revision/connectivity revision. Incoming Primary, Logo and
Backdrop tags define hydration reuse; retained details cannot override a newer
input revision or another catalog scope. Valid optional imagery survives inactive
focus changes and offline cache misses, but clears on source scope/role/revision
changes. Each optional image uses the existing
bounded authenticated generated-SDK image path and account-owned decoded cache.
Logo requests use PNG to preserve transparency. Primary cache keys retain their
existing namespace; role keys and remembered revisions cannot alias Primary or
another role. Optional imagery never substitutes a retained primary download cover.
Offline mode prevents metadata/network image reads while allowing known cached roles.

Focused coverage adds role/revision isolation, legacy Codable and absent/empty tag
fallback, and artist-detail mapping plus authenticated bounded Logo/Backdrop requests.
Formatting, syntax parsing and diff checks pass. The exact runtime candidate
`fe0b9de70af42ade6602fbc7c124cb5fa963b07b` passed 26 focused Mac tests
(25 artwork-cache/hydration tests and the artist metadata/image-request test) and an
iOS Simulator Release build using the pinned dependencies. Physical visual
acceptance remains pending. This is local development,
not publication or release acceptance. Player and account credential ownership are
unchanged. No live server mutation or private-content fixture is part of this patch.

Integrated local build 128 includes the reviewed sibling-role correction: the hero
invalidates metadata while each image loader owns scope/role/revision clearing.
The integrated candidate passed 27 focused Mac tests, signed macOS and iOS
Release builds, and signing verification. The installed Mac artist page visibly
showed the signature Logo, circular Primary portrait and fading Backdrop after
opening it from an album. This is a visual observation, not audible playback
acceptance. Build 128 was also installed, its version verified and launched on
the authorized iPhone 13 mini, preserving stored sign-in. Mobile visual spacing
and owner acceptance remain pending. The Mac inspector's continuous drag behavior
remains a separate unresolved owner check. No publication was performed.

Owner-requested build 129 simplifies the shared artist hero to Backdrop + Logo,
removing the Primary portrait on both platforms. The upper space keeps the
photograph visible before the centered logo and existing playback controls.
Missing Logo uses the artist name; missing Backdrop uses neutral dark tint.
The photo now fades into that neutral tint rather than sampling Primary artwork.
Album presentation and circular artist cards elsewhere are unchanged. macOS and
iOS signed Release builds and signing verification pass; lint and diff checks pass.
The installed Mac artist page visibly showed the backdrop and logo without a
portrait circle. Physical iPhone visual acceptance remains pending. Existing
artwork/task regression tests from build 128 remain the prior evidence; no new
tests were added for this layout-only change. No publication was performed.

Build 131 extends the shared artwork pipeline to display-density renditions
(160/640/1280/2048 pixels), including the doubled genre crop. Initial thumbnails
can appear softly blurred while the owned upgrade loads; higher-quality warm
images are retained through local-only mode and decode failures. Artist Backdrop
uses 2048 and transparent Logo uses 1280, with the existing byte, memory, disk
and concurrency limits. Final cache reads cannot mistake smaller previews for
completed upgrades; provider requests remain bounded at 2048. Default system
Now Playing decoding stays 640 while app presentation can upgrade its image.

Artist pages follow Light/Dark appearance. A bounded alpha-aware sRGB check
keeps a readable original logo, inverts when that meets the contrast target, or
uses a transparent monochrome wordmark/text fallback. VoiceOver retains the
artist-name heading. Light/dark, opaque and transparent fixtures are covered;
this is targeted contrast handling, not complete accessibility certification.
The shared responsive order is Logo, Overview, Controls: wide layouts put Logo
and Overview in a vertically centered row, with controls centered beneath;
narrow layouts stack those elements. Artist fades use eased stops and the same
endpoint color as the content surface to remove the boundary seam.

44 focused artwork/cache/provider tests pass. Final signed macOS and iOS Release
builds, signing verification and lint/diff checks pass. Build 130's Mac visual
check showed the inverted logo and horizontal layout; build 131 applies the
matching-surface fade correction. Mobile appearance and actual server-original
resolution/preview timing remain owner acceptance checks. No publication was
performed.

Final build 131 installed and version-verified on Mac and iPhone 13 mini.
Mac visual verification showed the readable inverted logo, side-by-side branding
row and continuous fade into the matching content shade. iPhone automatic launch
was blocked by the lock screen; installation succeeded and stored sign-in was
preserved. Mobile visual and live light-mode acceptance remain pending.


Build 140 supersedes the prior hero ordering. Play/Shuffle/Favorite now precede
the branding on both platforms. Wide layouts allocate 40% to Logo and 60% to
Overview, vertically centered; narrow layouts stack Logo then Overview below
the controls. A native material with an eased bottom-up mask retains backdrop
color behind the controls/branding instead of the localized dark logo backing.
Artist pages follow appearance; logo contrast estimates reflect the frosted
surface, but actual busy-backdrop Light/Dark acceptance remains pending.

On Mac the artist titlebar is transparent at the top and reveals a light native
frost on scrolling. The default title beside Back is empty; the centered title
appears after the hero logo leaves view. Native toolbar visibility remains
stable while the noninteractive frost overlay changes opacity. Each navigation
occurrence owns a separate header preference, including a root artist page.
The active route selects its own state, preventing a scrolled parent artist from
frosting the top of a related artist page. Repeated artist entries have distinct
route identities. Existing album title/navigation presentation is retained.

Runtime source `5bdc6bb5bd8a6f8c28828743850b80628a7285e1` passed signed Mac/iOS Release builds, strict signing
verification, formatting and diff checks. The installed Mac check confirmed
controls above the branding, transparent top, a centered title/frost after
scrolling, and a clear header after opening a related artist at its top.
Captured sidebar clipping was not reproduced on the owner's actual display;
no sidebar sizing workaround was retained for that capture artifact.
The iPhone 13 mini installation and installed build-140 verification succeeded;
automatic launch was blocked by its lock screen. Mobile visual acceptance,
root-artist scrolling and repeated-same-artist back/forward remain owner checks.
The previous 44 artwork/cache/provider regression tests and contrast fixtures
remain the evidence for unchanged artwork logic; layout changes have no new
implementation-mirroring tests. Sign-in and app identity are preserved.
Earlier installed builds are retained locally. No publication was performed.


Build 142 softens the shared artist frosted band with native thin material.
The eased mask begins at 42% of hero height (previously 22%) and reaches full
material at 77%, keeping the upper photograph clearer. The hero layout height
is unchanged, as requested. The footer still blends into the content surface.
Runtime source `758381c4ee2075045b6c43421c127ba4b0cd5dcd` passed signed macOS/iOS Release builds, strict signing,
formatting and diff checks. Installed Mac artwork visibly retains more photo
detail around the controls with a shorter frosted band behind Logo/Overview.
The iPhone 13 mini installation, build-142 verification and launch succeeded.
Owner appearance acceptance, particularly Light/Dark and mobile, remains pending.
No new tests were added for this reversible material/mask adjustment. No
publication was performed; sign-in and prior installed Mac build are preserved.


Build 143 keeps the owner-accepted frost height and reduces its material mask
opacity to 65% of the previous strength. Reduce Transparency retains its opaque
fallback. Fade positions, hero layout and footer blending remain unchanged.
Runtime source `f42a5505663eb58ab4dc97f482ea69d27b911852` passed signed Mac/iOS Release builds, strict signing,
formatting and diff checks. The installed Mac artist check visibly shows more
photo detail behind Logo/Overview. The iPhone 13 mini installation, build-143
verification and launch succeeded. Final appearance and busy-photo Light/Dark
readability remain owner checks; previous contrast estimates are not measured
contrast certification for the weaker material. No new tests were added for
this reversible opacity adjustment. Previous Mac build and sign-in are preserved;
no publication was performed.


Build 144 raises the shared artist frost start from 42% to 37% of hero height,
keeping the full-strength endpoint at 77% and the reduced 65% material opacity.
Runtime source `fac51c4bcb9496fd52e08a058c32571d1f8244b2` passed signed Mac/iOS Release builds, strict signing,
formatting and diff checks. Mac visual verification shows the modest upward
extension. iPhone 13 mini installation, build-144 verification and launch
succeeded. Owner appearance acceptance remains pending; no new tests were
added for the reversible gradient-stop adjustment. Previous Mac build and
app data are preserved; no publication was performed.


Build 145 adds an independently masked 12-point photo blur beneath the native
frost. The eased blur starts at 28% of hero height and reaches full strength at
66%, extending softly above the unchanged lighter frosted band toward Overview.
Both photo layers share the same image, crop and geometry; there are no extra
artwork requests or new cache ownership. Reduce Transparency skips the blur.
Runtime source `8d2deecc7ca1bf8109e6a7286b178b2852fd275e` passed signed Mac/iOS Release builds, strict signing,
formatting and diff checks. The installed Mac artist view visibly shows a clear
upper photo grading smoothly into blur behind the controls and branding.
Owner appearance and mobile visual acceptance remain pending. No new tests were
added for this reversible visual adjustment; no publication was performed.
The iPhone 13 mini installation and build-145 verification succeeded; automatic
launch was blocked by its lock screen. Previous Mac build and app data are preserved.


Build 146 reduces the artist photo blur radius from 12 to 8 points. Its mask
extent, native frosting opacity and layout remain unchanged. Runtime source
`c2dc11f9b4c25eedbec3ce3ac832cd272c4a3d2a` passed signed Mac/iOS Release builds, strict signing, formatting and
diff checks. Installed Mac artist visual verification confirms the softer blur
transition; iPhone 13 mini installation, build-146 verification and launch
succeeded. Owner visual acceptance remains pending. Previous Mac build and app
data are preserved; no new tests or publication for this visual-only adjustment.


Owner accepted build146 Mac appearance, then requested tighter mobile spacing
and a slightly lower Mac photo-blur start. Build148 integrates iOS artist hero
gaps of 12 points (previously20); Mac gaps remain20. Mac photo blur begins at33%
of hero height (previously28%), reaching full strength at the same66%; mobile
keeps its28% start. The8-point radius and65% frosting remain unchanged.
Runtime source `ae594d2881e8e39752d7f0027c55075b8a242b4e` passed signed Mac/iOS Release builds, strict signing,
formatting and diff checks. Installed Mac artist visual verification confirms
the lowered photo-blur transition. iPhone13mini install and build148 verification
succeeded; its lock screen blocked automatic launch. The intermediate147 mobile
install likewise succeeded but was lock-blocked. Mobile spacing acceptance
remains an owner check. Existing app data and prior Mac146 are preserved.
No new tests or publication were added for these reversible visual adjustments.


Build152 shares the accepted artist photo blur/frost/fade in a presentation-only
FoundationArtworkAtmosphere. It receives decoded artwork and adds no loading,
provider requests or cache ownership. Artist parameters remain unchanged; mobile
album backdrops use the same effect through the existing CatalogArtwork loader,
including initial preview blur while upgrading. Mobile Now Playing adapts the
effect's start to the measured controls area, replacing its uniform28-point blur.
The full Player is mobile-only; Mac keeps its existing transport and inspector.
Reduce Transparency retains its fallback.

Albums place Play/Shuffle/Favorite before the title and overview. Mobile branding
is centered and keeps12-point spacing; Mac retains cover artwork beside leading
text and a four-line expandable overview with natural/minimum height. The external
mobile album overview was removed to avoid duplicate reads/presentation.
Album and artist toolbar titles remain in stable geometry and reveal continuously
over48points with eased opacity,8-point offset and a small scale adjustment.
Reduced Motion uses opacity only. Mac native album titles beside Back are suppressed
so the centered scroll title owns the reveal; active-route frost ownership remains
intact and its visibility eases over250ms. Pin glyphs fit a16-point image inside
the normal20-point toolbar label; native button hit areas and accessible labels
are retained.

Runtime source `333a47128551694d51d0965f3ea45594caaa5c80` passed signed Mac/iOS Release builds, strict signing,
formatting/diff checks and33 focused Mac tests (21Presentation +12CurrentArtwork).
A read-only review found no blocking geometry/task/cancellation regression and
identified the corrected mobile subtitle alignment. The installed Mac check
confirmed album controls above branding, no native title at the top, a centered
scroll title after the hero passed, retained artist atmosphere and proportionate
Pin glyph. Static captures confirm endpoints; subjective motion smoothness remains
an owner check. iPhone13mini installation, build152 verification and launch
succeeded. Mobile album/Now Playing visual acceptance, accessibility settings and
Light/Dark/busy-art readability remain pending; no new audio/server acceptance is
claimed. Prior Mac builds and sign-in are preserved; no publication was performed.


Owner rejected build152's shared blur/control layout experiment. Build154 restores
FoundationArtworkView and FoundationPlayerView exactly to accepted148 source
`ae594d2`, and restores the prior detail hero and external album overview.
Per the owner's follow-up, iOS album controls remain above title/subtitle and
overview; Mac album controls return below cover/text. Artist spacing/atmosphere
remain the accepted148 treatment. The smaller Pin glyph and gradual toolbar
reveal are retained. The shared reveal now requires actual vertical scrolling
and resets retained title geometry on item identity changes on both platforms.

Mac titlebar grading uses a smoothstep mask without the former opaque plateau.
Native top scroll-edge frosting is suppressed only for artist/album details
(`followsAppearance || scrollTitle`), leaving the owner-scoped custom fade as
the single treatment; playlist native edge behavior remains unchanged.
Runtime source `c47691fac14c08230e3a5d1d4789fd6d42c7bff2` passed signed Mac/iOS Release builds, strict signing,
formatting/diff checks and33 focused Mac tests. The installed Mac check confirmed
restored album control placement, retained artist styling/Pin and a single eased
header fade over a pale backdrop. Fine grading/subjective motion remain owner
checks. iPhone13mini install, build154 verification and launch succeeded.
The owner confirmed iOS album controls are fine and clarified the remaining top
chrome issue is the frosted background, not title text. The native iOS frost fix
is pending; build154 does not claim that background issue is resolved. No
publication was performed; prior builds and app data are preserved.


Build155 adds the owner-confirmed native iOS titlebar background correction: on
iOS26+, artist/album detail scroll-edge frosting is explicitly hidden at the top
and returns when the owning vertical scroll view reports movement. Other detail
kinds retain their existing edge behavior. The reduced Pin, gradual title reveal,
restored artwork/Now Playing code and iOS album controls-before-title remain.
Runtime source `d89e01db2cf8d3e14cb9932b7b47d4a53ce78ec1` passed signed Mac/iOS Release builds, strict signing,
formatting/diff checks. The exact154 selective rollback previously passed33
focused presentation/artwork tests; no repeated tests were added for this iOS-only
native edge-visibility modifier. iPhone13mini install, build155 verification and
launch succeeded. The owner confirmed the mobile titlebar background now behaves
correctly at the top and after scrolling. The Mac remains running154 with the rollback and grading fix to avoid another testing
interruption; its155 companion artifact is built and verified. No publication.

Build156 extends the clear-at-top/frosted-on-scroll Mac toolbar through the shared
navigation-content wrapper. Home, New, Favorites, Songs, Genres, Albums, Artists,
playlist indexes and detail destinations use the same treatment. Native Mac top
edge frosting is suppressed so the existing eased smoothstep material is the
single layer. Each root/destination owns its scroll preference; retained ancestors
cannot leave frosting on a new page at the top. Detail title reveal remains
independent, and accepted iOS155 edge visibility is unchanged.

Runtime source `7a14a2e7cb94033138cbb8122197dd96b8177f48` passed signed Mac/iOS
Release builds, strict signature verification and diff checks. Independent
read-only review found no blocking route/scroll ownership issue. Installed Mac156
checks confirmed Home clear at top and frosted when scrolled, album destination
clear at top, and Back restoring Home's scroll/frost state. A horizontal shelf
gesture at Home's top left the toolbar clear, although horizontal movement itself
was not established by automation. Playlist top was clear; a later scrolled Songs
capture showed the same fade (owner navigation intervened, so playlist scrolling
is not claimed). Subjective motion and exhaustive per-page visual acceptance remain
owner checks. No new unit-test result is claimed for156; the prior33 focused
presentation/artwork checks remain154 evidence. Mac156 is installed; iOS156 is
built/verified only and iPhone retains owner-accepted155. No publication.

Build157 bounds artist photo blur, material frosting and footer fade below the
measured playback row plus an eight-point clear gap. Hero-local geometry includes
the artist identity, so responsive widths, text sizing and artist navigation
cannot reuse another page's boundary. The eased ramp has an explicit clear stop
at that boundary, preventing interpolation above it. Strength, branding layout,
controls and toolbar behavior remain the accepted treatment.
Runtime `0da7dd8cb959f68723b0c1ddaea0fc72c9ac4fce` passed signed Mac/iOS Release
builds and diff checks. Independent review found no remaining scoped blocker
after correcting ramp interpolation and identity ownership. Installed Mac157
visual check confirmed clear artwork around the playback row and frosting around
branding/overview. Mac156 backup and stored data are preserved. iPhone13mini
install and build157 verification passed; launch was blocked by the lock screen,
so mobile visual acceptance remains pending. No new unit tests were added for
this reversible visual adjustment and no publication was performed.

## Integrated entitlement and UI test, builds158–160

The owner enabled CarPlay Audio for the existing production App ID. Refreshed
development provisioning and the signed iPhone artifact both contain the audio
entitlement. The first maintained-app increment presents native Now Playing
through the existing account-owned player/MediaSession. Shared startup is awaited
without a second player or autoplay. The preserved synthetic Home/New/Library
prototype has not yet been integrated into live CarPlay browsing or queue editing.

Build159 phone startup crashed with repeated SwiftUI `AppSceneDelegate.responds`
frames and stack exhaustion. Build160 returns a fresh phone scene configuration
instead of recycling SwiftUI's existing delegate proxy. The iPhone13mini install,
version check and cold launch passed; its process remained running and native
CarPlay showed the restored paused session. The newest retrieved app crash report
still names159. This is scoped startup evidence, not exhaustive crash acceptance.
Build158's native Play/Pause changed state and advanced progress; the owner did
not confirm audible output. Audible routing, locked cold start, reconnect, other
display configurations and full browsing remain pending.

Runtime source `fc84986bf514af796bef02d0f9fecdcb1700aa90` includes:

- New Tracks uses the grouped recent-music cache consistently through library
  scope resets, excluding legacy track-date ordering. A repeated-scope regression
  passed; server ordering remains dynamic. Live comparison with the owner's
  newest additions is still pending; the issue is not closed on cache evidence.
- Mac settings remove cellular streaming/download controls and Sign In Again.
  Stored preferences, iOS controls and actual sign-in/error recovery remain intact.
  A Settings-only public native window attachment fixes preference-style toolbar
  layout; observed Downloaded Music has Back/title leading and Edit trailing.
- Mac sidebar labels retain full-width36-point hit areas with consistent18-point
  icons and zero vertical row insets. Actual24-point list-container padding
  replaces the ineffective contentMargins modifier; album/playlist grids keep
  their existing24-point inset. Horizontal shelf underlap is untouched.
- The fixed profile container uses native interactive Liquid Glass, with a solid
  accessibility fallback under Reduce Transparency. Earlier material frosting
  was replaced at the owner's request.
- Mac Home previews use up to12 retained items per shelf, with existing carets and
  horizontal scrolling. No extra pagination/scans were introduced. Favorites
  sections order Playlists, Albums, Tracks, Artists on both platforms.
- Logo evaluation preserves readable original colors first, estimates the local
  backdrop/frost region, restricts inversion to grayscale marks and uses explicit
  black/white or text only after contrast failure. Opaque readable wordmarks keep
  their own backgrounds. This bounded heuristic is not formal certification.
  Local builds enable `VELACANTO_ARTWORK_DIAGNOSTICS` to show the chosen treatment
  and branch reason; ordinary builds omit the indicator. An installed Mac artist
  check visibly reported Original with the local-surface pass reason.

Signed Mac/iOS160 Release builds and strict signature checks passed. Nine iOS
startup/routing tests and19 final Mac startup/artwork tests passed. Earlier109
focused checks include the unchanged New Tracks regression. Independent scoped
reviews found no remaining blocker. Live Mac checks confirmed the corrected
Settings toolbar, effective Songs inset, tighter sidebar, Liquid Glass footer,
12-item Home preview and logo badge. Exhaustive per-page, appearance/accessibility,
overflow scrolling and owner visual acceptance remain pending. Existing app IDs,
sign-in and prior Mac builds are preserved. Xcode's generated untracked cloud
configuration is retained separately; no publication was performed.

The final frozen-source iOS rebuild changed executable bytes after the Mac-only
compiler correction, so it was installed again and cold launch/process presence
rechecked successfully. The app remained running and no newer app crash report
was present. Automated reopening from the CarPlay app grid did not complete after
that replacement; the owner's manual reopen check is pending. Do not extend the
earlier160 native screen observation to this final reopen without confirmation.

The owner subsequently confirmed the final160 app opens from the existing
CarPlay app grid. The manual reopen gate passes; audible output and the broader
CarPlay acceptance checks above remain pending.
