# Upstream source inventory

The [parity ledger](parity-ledger.json) is a reproducible **source-family discovery
baseline**, advancing [B2 / issue 13](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/13).
It is not a completed semantic applicability audit or evidence of port coverage.
The pinned Fortress revision is `f13cd5c0f2815926785a395947e18da0dbea0dd8`.

The snapshot contains 632 upstream files, including hidden files, and 337 classified
source/documentation/verification families. Each file has a SHA-256 hash. Classified
records additionally bind their source revision, source identity, provisional
protected behavior, owning task/epic, and lexical discovery markers. Cargo feature
maps are extracted from every Cargo manifest without evaluating feature gates.

## Reproduction and drift checks

First obtain the verified archive using the reference fetch workflow. The scanner
reads the extracted cache without executing upstream code or modifying it:

```sh
python3 scripts/reference/inventory.py
python3 -m unittest discover -s scripts/reference -p test_inventory.py -v
python3 scripts/reference/inventory.py --release
```

The first command must pass against the pinned extraction. The last command must
currently **fail**: schema 1 records discovery only, the semantic audit is incomplete,
and every decision is pending. It is intentionally unsuitable for release approval.
Even changing all records to `covered` cannot certify a release using this schema.
A future semantic ledger and executable test-evidence verifier are required before
release certification can be implemented; [issue 55](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/55)
records that verifier's evidence boundary and negative controls.

`--root`, `--pins`, and `--ledger` allow isolated verification. `--write` creates a
new ledger only and refuses overwriting an existing file. For a reviewed baseline
upgrade, generate a separate candidate file, inspect added/removed/changed identities,
then reconcile decisions and retain retired evidence before replacing the baseline.
This tool does not silently reconcile or delete old applicability decisions.

Every file participates in drift detection, including unknown extensions and
unclassified files. Additions, deletions, renames, inline test changes and feature
changes fail verification. A rename appears as deletion plus addition; matching
semantics across a rename is a review task. Symlinks fail scanning. Classifier or
marker changes also invalidate the baseline even if source files are unchanged.
The scanner does not independently authenticate its input tree during initial
creation: the verified fetch establishes provenance; subsequent scans check exact
file contents against the committed baseline.

## Schema and limits

`inventory.files` is the exhaustive file/hash map. `inventory.records` contains
source-family records identified as `fortress:<archive-relative-path>`; source
identity is independent of line numbers. `markers` are `[kind, line, source text]`
lexical candidates. Markers discover public declarations, all Rust function names,
test attributes, property/fuzz macros, cfg/default candidates, documentation fences,
allocation references and formal declarations. They do not resolve module paths,
macro expansions, visibility, nested cfg inheritance or assertion semantics.
Hashes preserve the entire file even when lexical extraction misses a construct.
Documentation fences may contain non-Rust code or intentionally failing examples.
No marker is counted as a passing test or individually reviewed contract.

`decisions` is keyed by source identity and includes status, applicability,
rationale, port test IDs and review evidence. Allowed statuses are `pending`,
`covered`, `deferred`, `not-applicable` and `intentional-divergence`. Every generated
decision is `pending` with `unknown` applicability and no mapped port test IDs.
Owning tasks are conservative routing suggestions, explicitly provisional; unknown
sources stay assigned to B2 instead of disappearing. Known-failure, legacy-wire,
regression and witness artifacts remain pending evidence, including Loom/Kani/SMT
and allocation-related assets. Rust-specific execution mechanisms are not grounds
for discarding behavioral obligations.

## Scoped queue source audit

The [input queue contract](../input-queue.md) reviews ordinary delay, retained
actual input and prediction-episode semantics in `src/input_queue/mod.rs` and
`src/input_queue/prediction.rs`. Those two decisions record the scoped source
inspection, while retaining `pending` status and `unknown` whole-family
applicability. Queue mechanisms share their source family with advanced
membership, recovery and Rust verification obligations. Schema 1 cannot express
that split, so the audit does not certify those families or complete B2.

## Remaining B2 requirements

Issue 13 stays open. The next source audit must:

- Split families into stable semantic API/configuration/default/feature and
  invariant entries, resolve each lexical candidate, and review ownership.
- Identify passing contracts versus old, intentionally failing or known-failure
  fixtures; preserve all fixtures with their expected outcome and provenance.
- Decide applicability for Rust/runtime-specific mechanisms while retaining
  relevant concurrency, ownership, bounded allocation and error obligations.
- Map supported behaviors to real Godot port test IDs and reproducible test evidence;
  introduce a semantic release gate that verifies the evidence rather than trusting
  arbitrary test ID strings or an audit-complete flag.
- Audit canonical local guidance against upstream events, frame semantics, binary
  formats, timer boundaries and reusable formal models; audit SignalFish lifecycle
  against its separately pinned SDK/server trees. Those trees are outside this
  Fortress-only discovery snapshot.

Source families route to their existing milestone tasks; unresolved semantics and
the guidance audit remain explicitly owned by B2. This snapshot cannot close B2
or its parent epic.
