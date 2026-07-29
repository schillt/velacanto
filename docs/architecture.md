# Velacanto architecture

This document describes the intended 0.1.0 structure. It is a design target,
not a claim that every component has already been implemented.

## Component map

```mermaid
flowchart TB
    User["User"]
    SystemUI["Lock Screen, Control Center, routes"]

    subgraph Presentation["Platform presentation"]
        IOS["iOS SwiftUI"]
        Mac["macOS SwiftUI"]
        CarPlay["CarPlay later"]
    end

    subgraph Application["Application state"]
        Coordinator["App state and coordinator"]
        Models["Shared domain models"]
    end

    subgraph Core["Shared core services"]
        Session["Session service"]
        API["Jellyfin API client"]
        Library["Music library repository"]
        Playback["Playback coordinator"]
    end

    subgraph Sources["Playback source adapters"]
        LocalAdapter["Local Files adapter"]
        JellyfinAdapter["Jellyfin adapter"]
        NavidromeAdapter["Navidrome adapter later"]
    end

    subgraph Apple["Apple platform services"]
        Networking["URLSession and local-network policy"]
        Keychain["Keychain"]
        AV["AVFoundation and AVAudioSession"]
        Media["Now Playing and remote commands"]
    end

    LocalFile["User-selected audio file"]
    Jellyfin["Jellyfin server"]
    Navidrome["Navidrome server later"]

    User --> IOS
    User --> Mac
    IOS --> Coordinator
    Mac --> Coordinator
    CarPlay -. "after core playback" .-> Coordinator

    Coordinator --> Session
    Coordinator --> Library
    Coordinator --> Playback
    Coordinator --> Models

    Session --> API
    Session --> Keychain
    Library --> API
    Library --> Models
    Playback --> Models
    Playback --> LocalAdapter
    Playback --> JellyfinAdapter
    Playback -. "future" .-> NavidromeAdapter
    LocalAdapter --> LocalFile
    JellyfinAdapter --> API
    NavidromeAdapter --> Networking
    API --> Networking
    Networking --> Jellyfin
    Networking -. "future" .-> Navidrome
    Playback --> AV
    Playback <--> Media
    Media <--> SystemUI
```

Every source adapter resolves its own selection into the same provider-neutral
playback request. The coordinator therefore sees a playable URL and metadata,
not Jellyfin, Navidrome, or file-picker details. Local Files passes the selected
URL through unchanged and holds its security-scoped access only for the active
item. The app owns this coordinator rather than an individual view, so playback
and the temporary file-access lease survive navigation and backgrounding until
the user stops playback, replaces the item, or the app terminates.

## Local-file playback journey

```mermaid
sequenceDiagram
    actor User
    participant UI as SwiftUI
    participant Files as System file picker
    participant Adapter as Local Files adapter
    participant Player as Playback coordinator
    participant AV as AVFoundation

    User->>UI: Open Audio File
    UI->>Files: Request one audio file
    Files-->>UI: Security-scoped file URL
    UI->>Adapter: Create playback request
    Adapter-->>UI: Same URL plus temporary access lease
    UI->>Player: Play request
    Player->>AV: Play selected URL in place
    User->>Player: Stop or replace item
    Player->>Player: Release file access
```

## Primary user journey

```mermaid
sequenceDiagram
    actor User
    participant UI as SwiftUI
    participant App as App coordinator
    participant API as Jellyfin API client
    participant Keys as Keychain
    participant JF as Jellyfin server
    participant Player as Playback coordinator
    participant OS as Apple media surfaces

    User->>UI: Enter server URL
    UI->>App: Connect
    App->>API: Validate server
    API->>JF: Request public server information
    JF-->>API: Server identity

    User->>UI: Submit credentials
    UI->>App: Authenticate
    App->>API: Authenticate user
    API->>JF: Username and password
    JF-->>API: User and access token
    API-->>App: Authenticated session
    App->>Keys: Store access token

    User->>UI: Browse music
    App->>API: Request libraries, albums, and tracks
    API->>JF: Authenticated metadata requests
    JF-->>API: Music metadata
    API-->>App: Decoded music models
    App-->>UI: Browse state

    User->>UI: Select track
    UI->>App: Play item
    App->>API: Resolve Jellyfin stream URL
    API->>JF: Request playable stream
    JF-->>API: Stream response
    API-->>App: Provider-neutral playback request
    App->>Player: Play request
    Player->>OS: Publish playback state and metadata
    OS-->>Player: Play, pause, stop, toggle, and seek
```

## Background and system-control lifecycle

```mermaid
sequenceDiagram
    participant App as App-lifetime state
    participant Player as Playback coordinator
    participant Audio as AVAudioSession and AVPlayer
    participant Media as Now Playing and remote commands
    participant System as Lock Screen and Control Center

    App->>Player: Retain one coordinator
    Player->>Audio: Activate playback audio session
    Player->>Media: Publish item, timing, and playback rate
    Media->>System: Present current media controls
    System-->>Media: Play, pause, stop, toggle, or seek
    Media-->>Player: Forward command
    Player->>Audio: Apply command
    Player->>Media: Publish updated state
    Note over App,Audio: View navigation does not release the player
```

## Responsibilities

| Component | Owns | Must not own |
| --- | --- | --- |
| SwiftUI surfaces | Presentation, navigation intent, accessible controls | Endpoint construction, token persistence, audio-session policy |
| App coordinator | Session state, loading state, navigation state, service coordination | Raw Keychain, URLSession, or AVFoundation calls |
| Session service | Authentication, restoration, logout, stable device identity | Password persistence or library browsing |
| Jellyfin API client | Authenticated requests, endpoint details, response decoding | UI state or playback controls |
| Library repository | Music views, albums, tracks, artwork, browse errors | Credential storage or audio routing |
| Playback source adapters | Source-specific URL resolution and the shortest required access lifetime | Transport controls, audio-session policy, or unrelated source APIs |
| Playback coordinator | Player state, temporary resource access, audio-session policy, interruptions, routes, and system controls | User authentication, source-specific resolution, or library presentation |
| Platform adapters | Keychain, networking policy, audio, now-playing integration | Product navigation or domain rules |

## Security and privacy boundaries

- The password is transient and is not persisted by Velacanto.
- The access token is stored in Keychain and removed on logout.
- Tokens and passwords must not appear in logs, fixtures, screenshots, or Git.
- Remote servers use HTTPS by default.
- Local servers require an explicit local-network purpose string and the
  narrowest transport-security policy that supports the approved use case.
- The privacy manifest must reflect the APIs and data flows actually present in
  the shipped target.
- User-selected local files are played from their original URL. Velacanto does
  not copy, upload, index, or persist access to them.

## Intended source layout

The exact Xcode group structure will be confirmed during project generation.
The intended responsibility split is:

```text
Velacanto/
├── App/
├── Features/
│   ├── Connection/
│   ├── Authentication/
│   ├── Library/
│   └── NowPlaying/
├── Core/
│   ├── Models/
│   ├── Session/
│   ├── Playback/
│   └── JellyfinAPI/
├── Sources/
│   ├── LocalFiles/
│   ├── Jellyfin/
│   └── Navidrome/
├── Platform/
│   ├── Keychain/
│   ├── Networking/
│   └── Media/
└── Resources/

VelacantoTests/
├── JellyfinAPI/
├── Session/
├── Playback/
└── Features/
```

## Related documents

- [0.1.0 plan](0.1-plan.md)
- [Roadmap](roadmap.md)
- [Architecture decisions](decisions/README.md)
- [Interactive visualization](visualizations/README.md)
