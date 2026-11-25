# Native relay warmup frontier

The hosted eight-player Firefox 4.3 run in #488 lost its final page reads.
All eight partial console checkpoints lacked a confirmed frame. Queue counts
could show that a page was servicing packets, but they could not place it
relative to the gameplay gate.

| Finding | Evidence | Action |
| --- | --- | --- |
| A bounded service sample can carry the gameplay frontier through a page read failure. | The focused browser cleanup test first failed with `TypeError: late.frontier is not a function`. The revised control retains a playing frame 16 with confirmation 8 and independently records a cutoff received at the deadline. | Pair each warmup sample's queue counts, state and frames. Keep the page observation and controller receipt on their original clocks. |
| A failed tick can precede its terminal cutoff, and a second checkpoint can repeat the first cutoff's timestamp. | The adversarial review's terminal control first reported `observed_below_gate` for a failed tick. A separate control delivers a partial checkpoint after the terminal cutoff. | Classify failed ticks as terminal and retain the first valid cutoff. Keep diagnostic receipts separate from the receipts that open the barrier. |

The [browser witness guidance](../skills/testing/references/browser-integration.md)
now covers the two rules. The witness documentation adds the frontier to the
existing cutoff and packet-stage evidence. Those observations still measure
different parts of the warmup, so both remain current.

The focused command
`python3 -m unittest discover -s scripts/reference -p test_browser_cleanup.py -k timely_playing_gate -v`
covers pre-start, timely, late, missing and terminal receipts, including a
checkpoint whose ticks arrive in decreasing page-time order. Issue #489
tracks native expiry during a different phase.

State `findings-acted`.
