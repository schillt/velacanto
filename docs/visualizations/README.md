# Architecture visualization

`velacanto-app-structure.html` is a standalone interactive view of the
architecture established in 0.1. Its delivery-slice content is historical;
current release status lives in the [0.2 plan](../0.2-plan.md).

GitHub does not execute committed HTML files in the repository viewer. Download
the file or open it from a local checkout:

```sh
open docs/visualizations/velacanto-app-structure.html
```

The GitHub-rendered, editable diagrams are maintained in
[architecture.md](../architecture.md), while delivery status is maintained in
[roadmap.md](../roadmap.md). The runtime graph records the provider and
playback boundaries that 0.2 must preserve.

When a durable architecture or delivery change is accepted:

1. Update the Mermaid diagrams and responsibility boundaries in
   `architecture.md`.
2. Update current scope only in `0.2-plan.md` and `roadmap.md`.
3. Regenerate this standalone visualization only when the architecture graph
   itself changes.
4. Verify both visualization views at desktop and narrow widths before
   committing them together.
