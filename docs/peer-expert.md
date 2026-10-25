# Manual peer requests

`FortressPeerSession` supports callback and manual request modes. Both use the
same protocol, bounded input publication, confirmation, rollback and lifecycle
controls. Manual mode supplies no game object and invokes no hidden callbacks.
It lets an integration dispatch SAVE, LOAD and ADVANCE itself.

Configure with `configure_expert(config, local, handshake_options, input_options,
lifecycle_options = null)`. The arguments and validation match `configure`, except
there is no game argument. Begin the normal peer handshake and deliver packets
through the usual peer methods before attempting gameplay.

## Service a frame

| Method | Result |
| --- | --- |
| `begin_step(now_us, local_inputs)` | `Types.Result`; publishes the same `Driver.LocalInput` list as callback mode, then opens ordered requests |
| `begin_recovery(now_us)` | `Types.Result`; polls and repairs confirmed history without a new sample or forward frame |
| `begin_capture_replay_boundary()` | `Types.Result`; opens the same finalized-prefix SAVE used by callback replay capture, without polling or network publication |
| `complete_request(batch_id, request_id, callback_ok, checksum = PackedByteArray())` | `Driver.StepResult`; `READY` means requests remain, otherwise reports final peer controls and failure metadata |

A begin result with `READY` owns a bounded `batch`. Call `batch.next_request()`
to retrieve the active request. Repeated reads return that same request until
acknowledged. Dispatch it using the request's kind and frame:

```gdscript
var opened: Types.Result = peer.begin_step(now_us, samples)
if opened.code == Types.Code.READY:
    while true:
        var request: Types.Request = opened.batch.next_request()
        if request == null:
            break
        var ok: bool = false
        var checksum: PackedByteArray = PackedByteArray()
        match request.kind:
            Types.Kind.SAVE:
                var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
                ok = saved.ok
                checksum = saved.checksum
            Types.Kind.LOAD:
                ok = game.load_state(request.frame, request.reader)
            Types.Kind.ADVANCE:
                ok = game.simulate_frame(request.frame, request.inputs)
        var result: Driver.StepResult = peer.complete_request(
            request.batch_id, request.request_id, ok, checksum
        )
        if result.code != Types.Code.READY:
            break
```

This loop calls the application's own game methods; the peer only validates
acknowledgements. The application owns callback dispatch, ordering and success
validation. SAVE must write full canonical state and supply the configured
checksum; LOAD must consume the whole snapshot; ADVANCE must simulate once.
Check each returned code, including non-READY begin outcomes. A null request can
also indicate a terminal snapshot failure; inspect `peer.status()`.

## Ownership and completion

While a batch is pending, the peer returns `BUSY` for polling, delivery, another
begin, callback-mode stepping and delay changes. Packet, event and transition
drains return empty. Consume every request before servicing transport again.
This prevents new traffic from changing the input history being dispatched.

A successful intermediate acknowledgement returns `READY`; it publishes no new
frame and emits no completion signal. The final acknowledgement commits the
frame, services peer controls and emits `step_completed` once. Recovery can
finish without moving the frame. Idle recovery may return `OK` without a batch.
Read status and drain peer packets/events after the completed operation.
The completion guard and first-cause diagnostics match callback mode.

Acknowledgement expires each borrowed writer, reader or input view. Wrong,
duplicated or out-of-order identities return `STALE_REQUEST` without consuming
the active request. A completed or cancelled batch returns null forever, even
when a later batch is active. A failed callback acknowledgement or invalid
snapshot terminates the match and releases final lifecycle packets.

`close(now_us, reason)` explicitly cancels an outstanding manual batch and
expires its active view. An invalid close leaves that batch usable. A valid
close cannot resume the old game; create a fresh peer and game to restart.
Callback-only `step`, `recover` and `capture_replay_boundary` return `UNSUPPORTED`
in manual mode. Manual begin/acknowledgement calls return `UNSUPPORTED` in callback
mode. Modes cannot change after configuration.

Both engine pins compare public manual and callback peers under real encoded
traffic, multiple local slots, delay, loss, reordering, duplicate delivery,
prediction stalls, queue wrap and final recovery. Independent original-input
history checks corrected canonical prefixes. Focused controls cover request
identity, view expiry, callback failure, cancellation and publication pressure.
This local evidence does not qualify additional browsers or release platforms.
