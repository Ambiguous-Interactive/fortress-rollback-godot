# Retrospective — 2026-11-28 pinned donor departure

## Findings and actions

A source witness can conflate message delay with the disappearance of its
selected donor. The paired v6 observer now keeps the donor active for
300 ms in a separate held-delivery control. Those recipients still have
their original pending state at release and certify cut 8 afterward.

The terminal source path now invokes advancement directly after routing
the original late chunk. An input-submission error could otherwise hide a
call that never reached advancement. The confirmation frontier also
defines which callback rows enter the continuation record. The sampled
row at frame 17 could still be predicted when frame 16 was confirmed.

The first terminal sample is 220 ms after the selected donor went silent.
The source keeps both logical slots connected and emits no abort or commit.
Godot reports participant loss on explicit Goodbye. Both preserve their
original exposed rows. The comparison validates each runtime's public
outcome with its own departure trigger and clock.

## Outcome

State is `findings-acted`. The [evidence guidance](../skills/testing/references/oracle-validation.md)
records the paired hold and direct advancement checks. The
[comparison guide](../../docs/oracle-p2p.md#selected-history-donor-leaves)
keeps the live transport scope under #188.

The delivery review exposed two accepted false positives in the carried-forward
validator. A COMMIT from endpoint 99 passed with no installed history, and
duplicate late socket order passed with no read clock. The comparison now
requires the real coordinator broadcast, installation and public drop before
continuation. Socket reads record their own clock and unique order. The Godot
test emits the observed Goodbye, failure reason, replay rows and refusal codes
for independent comparison. Mutations of those records prove the new checks.
The first installed sample also showed a documented transient decrease in the
source confirmation accessor. The receipt keeps that sample separate from
the settled confirmation and checks each predicted snapshot from original
inputs and the local versus remote prediction rule.

The exported room closes the selected donor's browser context while the
recipient holds the donor's original WebRTC packet. Both remaining SDKs
report the same player departure. The adapter requires a room restart and
refuses the held packet. The pending rollback barrier preserves its replay.
The paired delivery control installs the same bytes and commits cut 6.

Both Chromium receipts originally accepted the other live page index as
the selected donor. The browser controller now records every UUID in page
order. Both pinned receipts reject a changed index or swapped evidence.
The SDK notice deadline starts on each remaining page's controller marker.
The earlier wait for history and the controller has its own bound.

Two reference suite runs found the fake engine receipt fixture waiting on a
real browser's host lease. Holding the default lease in a controlled run
reproduced the fixture's 30-second child timeout. A fixture-local capacity
directory passed the same test in 0.999 seconds while the default lease stayed
held. Real engine and browser probes retain shared host scheduling.

The hosted review reproduced a compile failure in the optional coordinator
mode. Its socket used an old initializer, and the ordinary v6 build omitted
that feature. All three modes now share a socket initializer. The ordinary
v6 build compiles coordinator failover, and its receipt records that feature.

The final hosted finding reproduced another matching-state false positive in
the browser receipt. A single altered accumulator byte passed when copied to
the controller and both recipient records. The witness now rebuilds the
speculative tail from bounded callback samples, checking original inputs and
predictions before applying them. Chromium and Firefox both reject the
matching corruption on each pinned editor.
