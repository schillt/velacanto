# Velacanto architecture

This document describes the intended 0.1.0 structure. It is a design target,
not a claim that every component has already been implemented. The
[roadmap](roadmap.md) is the source of truth for delivery status.

## Component map

```mermaid
flowchart TB
    User["User"]
    SystemUI["Lock Screen, Control Center, routes"]

    subgraph Presentation["Platform presentation"]
        IOS["iOS SwiftUI<br/>(prototype implemented)"]
        Mac["macOS SwiftUI<br/>(prototype implemented)"]
        CarPlay["CarPlay later"]
    end

    subgraph Application["Application state"]
        Coordinator["App state and coordinator<br/>(playback owner implemented)"]
        Models["Shared domain models<br/>(playback implemented; server planned)"]
    end

    subgraph Core["Shared core services"]
        Session["Session service<br/>(Slice 1 planned)"]
        API["Jellyfin API client<br/>(Slice 1 planned)"]
        Library["Music library repository<br/>(Slice 2 planned)"]
        Playback["Playback coordinator<br/>(foundation implemented)"]
    end

    subgraph Sources["Playback source adapters"]
        LocalAdapter["Local Files adapter<br/>(implemented)"]
        JellyfinAdapter["Jellyfin adapter<br/>(Slice 3 planned)"]
        NavidromeAdapter["Navidrome adapter<br/>(after 0.1)"]
    end

    subgraph Apple["Apple platform services"]
        Networking["URLSession and local-network policy<br/>(ATS foundation implemented)"]
        Keychain["Keychain<br/>(Slice 1 planned)"]
        Engine["Audio player engine<br/>(implemented)"]
        AV["AVFoundation and AVAudioSession<br/>(implemented)"]
        Media["Now Playing and remote commands<br/>(implemented)"]
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
    Coordinator --> LocalAdapter
    Coordinator --> JellyfinAdapter
    Coordinator -. "after 0.1" .-> NavidromeAdapter

    Session --> API
    Session --> Keychain
    Library --> API
    Library --> Models
    Playback --> Models
    LocalAdapter -- "PlaybackRequest" --> Playback
    JellyfinAdapter -- "PlaybackRequest" --> Playback
    NavidromeAdapter -. "PlaybackRequest" .-> Playback
    LocalAdapter --> LocalFile
    JellyfinAdapter --> API
    NavidromeAdapter --> Networking
    API --> Networking
    Networking --> Jellyfin
    Networking -. "future" .-> Navidrome
    Playback --> Engine
    Engine --> AV
    Playback <--> Media
    Media <--> SystemUI
```

Every source adapter asynchronously resolves its own selection into the same
provider-neutral playback request. The coordinator therefore sees display
metadata, an opaque resource lease, and a playback-asset factory rather than
Jellyfin, Navidrome, or file-picker details. Local Files passes the selected URL
through unchanged and holds its security-scoped access only for the active item.
The app owns this coordinator rather than an individual view, so playback and
the temporary file-access lease survive navigation and backgrounding until the
user stops playback, replaces the item, or the app terminates.

The main-actor playback engine owns AVFoundation and translates item readiness,
waiting, playing, pause, completion, stall, and failure events into an explicit
provider-neutral playback state. Periodic time observations update the in-app
progress display; system Now Playing metadata is republished only when the item,
duration, seek position, or playback state changes.

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
    UI->>Adapter: Resolve playback request
    Adapter-->>UI: Asset factory plus temporary access lease
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
    participant Adapter as Jellyfin adapter
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
    App->>Adapter: Resolve selected track
    Adapter->>API: Resolve Jellyfin playback info
    API->>JF: Request playable stream
    JF-->>API: Stream response
    API-->>Adapter: Provider response
    Adapter-->>App: Provider-neutral playback request
    App->>Player: Play request
    Player->>OS: Publish playback state and metadata
    OS-->>Player: Play, pause, stop, toggle, and seek
```

## Background and system-control lifecycle

```mermaid
sequenceDiagram
    participant App as App-lifetime state
    participant Player as Playback coordinator
    participant Engine as Audio player engine
    participant Audio as AVAudioSession and AVPlayer
    participant Media as Now Playing and remote commands
    participant System as Lock Screen and Control Center

    App->>Player: Retain one coordinator
    Player->>Audio: Activate playback audio session
    Player->>Engine: Load and control player item
    Engine->>Audio: Apply AVPlayer operations
    Audio-->>Engine: Readiness, timing, wait, end, failure
    Engine-->>Player: Observed playback state
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
| Playback source adapters | Asynchronous source-specific asset resolution and the shortest required access lifetime | Transport controls, audio-session policy, or unrelated source APIs |
| Playback coordinator | Observed player state, opaque resource leases, audio-session policy, interruptions, routes, and system controls | User authentication, source-specific resolution, or library presentation |
| AVFoundation playback engine | Player-item readiness, timing, waiting, completion, stalls, and failures | Source identity, navigation, or authentication |
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

## Source layout

The project now has the playback foundation in place. Planned directories are
listed here so new slices extend the established boundaries instead of moving
responsibilities into the prototype view:

```text
Velacanto/
├── App/                         # implemented: app-lifetime ownership
├── Features/
│   ├── Prototype/               # implemented: temporary foundation UI
│   ├── Connection/              # Slice 1
│   ├── Authentication/          # Slice 1
│   └── Library/                 # Slice 2
├── Core/
│   ├── Models/                  # implemented: source and playback contracts
│   ├── Playback/                # implemented: coordinator and player engine
│   ├── Session/                 # Slice 1
│   └── JellyfinAPI/             # Slice 1
├── Sources/
│   ├── LocalFiles/              # implemented
│   ├── Jellyfin/                # Slice 3
│   └── Navidrome/               # after 0.1
├── Platform/
│   ├── Media/                   # implemented
│   ├── Keychain/                # Slice 1
│   └── Networking/              # Slice 1
└── Resources/

VelacantoTests/
├── Playback/                    # implemented in the foundation test target
├── JellyfinAPI/                 # Slice 1
├── Session/                     # Slice 1
└── Features/                    # Slices 1 and 2
```

## Related documents

- [0.1.0 plan](0.1-plan.md)
- [Roadmap](roadmap.md)
- [Architecture decisions](decisions/README.md)
- [Interactive visualization](visualizations/README.md)
