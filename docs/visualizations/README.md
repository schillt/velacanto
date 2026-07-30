# Architecture visualization

`velacanto-app-structure.html` is a standalone interactive view of the intended
runtime architecture and the 0.1.0 delivery slices.

GitHub does not execute committed HTML files in the repository viewer. Download
the file or open it from a local checkout:

```sh
open docs/visualizations/velacanto-app-structure.html
```

The GitHub-rendered, editable diagrams are maintained in
[architecture.md](../architecture.md), while delivery status is maintained in
[roadmap.md](../roadmap.md). The runtime graph is the intended 0.1 architecture;
the status text on its nodes records which boundaries are implemented now.

When a durable architecture or delivery change is accepted:

1. Update the Mermaid diagrams and responsibility boundaries in
   `architecture.md`.
2. Update slice completion only in `roadmap.md`.
3. Regenerate this standalone visualization so its node status and delivery
   view reflect those two sources of truth.
4. Verify both visualization views at desktop and narrow widths before
   committing them together.
