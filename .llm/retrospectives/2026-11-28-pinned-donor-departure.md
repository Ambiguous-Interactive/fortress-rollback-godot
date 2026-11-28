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
