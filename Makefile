.PHONY: handshake-probes queue-probes oracle-probes test-oracle representation-probes lint-source hooks lint-llm test-llm test-reference reference-baseline
.PHONY: llm-index llm-index-prune pre-commit godot-check test-godot test-focus

PY ?= python3
GODOT ?= godot
CATEGORY ?= unit
SUITE ?=
FILTER ?=

## Enforce the 180-character maximum across repository source files
lint-source:
	$(PY) scripts/check_source_line_lengths.py

## Install git hooks (sets core.hooksPath to .githooks/)
hooks:
	git config core.hooksPath .githooks
	@echo "Installed hooks: commits now run the .llm harness checks."

## Validate the entire .llm harness (lengths, index, stubs, meta-lint)
lint-llm:
	$(PY) scripts/llm/check_llm_file_lengths.py
	$(PY) scripts/llm/generate_llm_index.py --check
	$(PY) scripts/llm/generate_skill_stubs.py --check
	$(PY) scripts/llm/lint_llm_instructions.py

## Run the harness tooling self-tests
test-llm:
	$(PY) -m unittest discover -s scripts/tests -t scripts

## Reference fetch/inventory negative controls (no network or downloaded tools)
test-reference:
	$(PY) -m unittest discover -s scripts/reference -p 'test_*.py'

## Offline scenario/trace and process-receipt negative controls
test-oracle:
	$(PY) -m unittest discover -s scripts/oracle -p 'test_*.py'

## Actual pinned Rust and production Godot queue comparison
queue-probes:
	$(PY) scripts/oracle/queue_launch.py --godot $(GODOT)

## Actual pinned upstream P2P handshake and production Godot byte endpoint
handshake-probes:
	$(PY) scripts/oracle/handshake_launch.py --godot $(GODOT)

## Actual upstream runtime traces and independent GDScript game replay
oracle-probes:
	$(PY) scripts/oracle/launch.py --godot $(GODOT)

## Fail-closed native GDScript tests, repeated in fresh processes
test-godot:
	$(PY) scripts/run_godot_tests.py --godot $(GODOT)

## Focused local iteration, preserving both fresh-process and in-process repetitions
test-focus:
	$(PY) scripts/run_godot_tests.py --godot $(GODOT) --category $(CATEGORY) $(if $(SUITE),--suite $(SUITE)) $(if $(FILTER),--filter $(FILTER))

## Minimum/current native and exported-Web representation and protocol checks
representation-probes:
	$(PY) scripts/reference/ownership_probes.py --web

## Pinned upstream reference tests, repeated with explicit seed and feature flags
reference-baseline:
	$(PY) scripts/reference/run.py --setup-rust

## Regenerate the skills index + agent discovery stubs (after .llm edits)
llm-index:
	$(PY) scripts/llm/generate_llm_index.py --write
	$(PY) scripts/llm/generate_skill_stubs.py --write

## Regenerate AND remove orphaned stub directories
llm-index-prune:
	$(PY) scripts/llm/generate_llm_index.py --write
	$(PY) scripts/llm/generate_skill_stubs.py --write --prune

## Everything the pre-commit hook runs
pre-commit: lint-source lint-llm test-llm

## Validate the Godot project headless (parse scripts, import assets)
godot-check:
	godot --headless --path . --import
