# Retrospective — 2026-11-28 departing history donor

## Findings and actions

A selected donor can leave while recipients still need its original row.
The fixture now holds its ordinary encoded history publication in a four-peer
mesh and uses real addressed Goodbye packets for both departures.

The first fixture counted three Goodbye copies per link as three different
recipients. It now checks the destination set and routes all copies.
The held data retains the first chunk per recipient, checks repeat bytes,
and binds each publication to the adopted target and operation.

Initial assertions checked termination after attempting late delivery.
The fixture now checks the terminal event, lifecycle and replay extent before
injecting the late original data. It repeats the state and extent check after
the late packet and failed step, and reads the original confirmed samples.
The paired delivery reaches a shared confirmed boundary across all survivors,
which prevents predicted donor state from satisfying the continuation check.

The isolated participant-guard control accepted late delivery and remained
running. The test exited 1. The native fixture and its ordinary delivery
control pass on both Godot pins. The live browser and pinned Rust terminal
comparisons remain separately scoped.

## Outcome

State is `findings-acted`. The [oracle evidence guidance](../skills/testing/references/oracle-validation.md)
records the terminal observation order. The
[lifecycle guide](../../docs/peer-lifecycle.md#unequal-confirmation-frontiers)
describes the covered donor-departure case.
