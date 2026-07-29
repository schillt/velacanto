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

    subgraph Apple["Apple platform services"]
        Networking["URLSession and local-network policy"]
        Keychain["Keychain"]
        AV["AVFoundation and AVAudioSession"]
        Media["Now Playing and remote commands"]
    end

    Jellyfin["Jellyfin server"]

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
    API --> Networking
    Networking --> Jellyfin
    Playback --> Jellyfin
    Playback --> AV
    Playback <--> Media
    Media <--> SystemUI
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
    UI->>Player: Play item
    Player->>JF: Request audio stream
    JF-->>Player: Audio bytes
    Player->>OS: Publish playback state and metadata
    OS-->>Player: Play, pause, and route commands
```

## Responsibilities

| Component | Owns | Must not own |
| --- | --- | --- |
| SwiftUI surfaces | Presentation, navigation intent, accessible controls | Endpoint construction, token persistence, audio-session policy |
| App coordinator | Session state, loading state, navigation state, service coordination | Raw Keychain, URLSession, or AVFoundation calls |
| Session service | Authentication, restoration, logout, stable device identity | Password persistence or library browsing |
| Jellyfin API client | Authenticated requests, endpoint details, response decoding | UI state or playback controls |
| Library repository | Music views, albums, tracks, artwork, browse errors | Credential storage or audio routing |
| Playback coordinator | Stream resolution, player state, interruptions, routes, system controls | User authentication or library presentation |
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
│   ├── JellyfinAPI/
│   ├── Session/
│   ├── Playback/
│   └── Models/
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
