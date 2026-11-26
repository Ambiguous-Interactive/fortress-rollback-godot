# Native departure and history

| Finding | Evidence | Action |
| --- | --- | --- |
| A frozen player departure revoked gameplay and detached every local WebRTC link in the same callback. | The baseline `mesh_departure` case recorded one mesh detach and one socket close before explicit Leave. Hosted mixed WebKit rooms attributed exact engine sends to surviving seats after the reciprocal SDK had started removing the link. | Revoke application routing and stop gameplay in the departure callback. Keep the survivor's mesh and signaling connection until explicit Leave. Validate the intended SDK removal while the surviving sockets are still open. |
| The original leave witness had separate roster sources for ordinary and mixed-path rooms. | The first native mesh assertion expected zero survivors from the mixed-path array in an ordinary eight-player room. The browser receipt showed seven survivors and seven open sockets. | Take the intended leaver and survivor identities from the Ready acknowledgements. |
| A native mesh can already own live routes while the example waits to start gameplay. | The startup and pre-start regression rows each recorded an early socket close when the lobby checked for the playing state. | Preserve a retained mesh according to the adapter lifetime. Exercise departure before startup, while waiting for links and during play. |
| An open signaling socket still needs service after gameplay stops. | The retention control recorded one poll instead of two. The pinned SDK calls the underlying WebSocket peer from its poll method. On both Godot pins, muting the client during departure let the current signal reach the mesh and suppressed a later plan. | Keep polling signaling in a stopped match and mute later SDK callbacks until Leave releases the mesh. |
| A failure after confirmed-history publication could discard the underlying rows. | Three browser controls lost complete, partial and divergent history when final status could not be read. A fourth control rejected an early capture before its sibling published. | Preserve timely per-page publications, compare complete rooms against the frozen roster and report the requested and compared counts separately. |

The [browser integration guide](../skills/testing/references/browser-integration.md)
now describes these observation points. Its previous read-failure guidance
covered only the later engine turn. The revised wording covers both receipts.

State `findings-acted`.
