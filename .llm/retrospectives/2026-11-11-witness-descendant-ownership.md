# Session 171 retrospective findings (acted)

Date: 2026-11-11. Artifact: progress/session-171-witness-ownership-and-evidence-binding.md.
PR: #351 (head `ddafd4e`). Issues addressed: #290 (named next step delivered),
#55 (evidence boundary implemented), #349 (delivery audit, closed as delivered).

## Finding 1 — wait-before-drain reintroduced the bug the old code never had

The owned runner called `process.wait(timeout)` and only then drained the
pipes. `wait` never reads, so any command that writes more than the kernel
pipe capacity blocks on `write()` forever and can only end at its deadline: a
strict regression against `subprocess.run(capture_output=True)` that no test
caught because every new control emitted a few bytes. A fresh adversarial
sub-agent proved the false timeout empirically against a 256 KiB child.
**Lesson: when replacing `subprocess.run`, enumerate the guarantees it provides
for free (concurrent drain, EOF-agnostic completion) and write one control per
guarantee, not per feature.** Fixed by merging the wait into the select drain
loop; the control now pushes >64 KiB through both streams.

## Finding 2 — an ownership mechanism that only reads the environment is half a mechanism

The token sweep catches token carriers anywhere, and the process-group check
catches same-session escapees that scrubbed their token — but a descendant
that both `setsid`s away and scrubs its environment defeats both nets, and the
three-line probe did exactly that while the module docstring claimed full
coverage. **Lesson: state the residual threat model next to the mechanism, in
the docstring and in the issue thread, before a reviewer states it for you;
an ownership claim that a probe defeats must be scoped as open work, not
shipped as a guarantee.** Cgroup-backed containment remains open in #290.

## Finding 3 — post-exit bytes and zombies were the flake class the first draft built in

Two probes showed the after-run boundary misreporting ordinary healthy runs:
a grandchild that exited before its parent stays a zombie holding the process
group open, so `killpg(pid, 0)` failed 6/30 healthy runs in this container;
and bytes a same-group descendant wrote after child-exit entered the returned
receipt output, an injection channel into regex-parsed receipts. **Lesson:
after-run boundary checks need the process state model (zombies are dead, a
group outlives its leader) and an output trust boundary (snapshot at exit,
withhold and log the rest), each with a real-process control that forces the
race deterministically.** Both are now controls that run in ~5 seconds.

## Finding 4 — the evidence ledger needed the boundary, not a bigger ledger

#55 could have pulled the session into a semantic-audit endevour. The scoped
slice — identity grammar always on, `--results` binding fail-closed against
launcher receipts, 15-row mutation table, bundle contract documented —
delivers the verifier boundary the issue asks for while leaving the release
gate untouched. **Lesson: for audit-shaped issues, implement the gate that
would reject forged evidence before filling the ledger it will eventually
guard; the gate is testable today, the audit is not.**
