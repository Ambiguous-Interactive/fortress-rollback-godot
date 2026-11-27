# Fortress v6 archive review evidence

This review covers the transition from `d124c890` to `25e8020d`. The
[archive report](fortress-25e8020d1a5fd40c4f16b37f97b5ec5329a8566d.json)
binds the paths and dispositions to both verified archives. Each evidence entry
names its path and retains the underlying observations. Its report reference
includes the SHA-256 of the evidence paragraph with lines joined by spaces.

### Decision 001

`.agents/skills/adversarial-handoff/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
865f80a32f7a1ffc81cd987d44b7c2cd107ebb4eb9d34d49021f71920164dda3 at the reviewed revision and
c7dba936e99719f6c900d8f3eb4a600202d2e68b37e911aa2e6e890e08b1ad5b at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/adversarial-handoff/SKILL.md

### Decision 002

`.agents/skills/ci-debugging/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
9e196e5b6570374768dfc155fd5766de382624de90b7ed94a31c667a7ace0faa at the reviewed revision and
a43fee6514de38b6a79958f7377e5c6fe2b3e93c2025f79c0ee78b3da3f7ef22 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/ci-debugging/SKILL.md

### Decision 003

`.agents/skills/code-review/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
aaf0ae4126fc47813f0a4133387f36c83e2d59945d70f4968a4e701d10869adb at the reviewed revision and
1d5b48496e491f5b2276fd35c3f3e0ba1a615c2035497d3ad6eed28dc93aa1d3 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/code-review/SKILL.md

### Decision 004

`.agents/skills/defensive-programming/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
b0496f83370266cca0a44539b920407f62e98814b1b3b6eadf21349fb998751a at the reviewed revision and
17844ad8190df0dca6d9d621737a7695f55ca181a9d5d461f3ee2fe5c17f39e5 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/defensive-programming/SKILL.md

### Decision 005

`.agents/skills/design-decisions/references/devcontainer.txt` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are absent at the reviewed
revision and e57e19902141c10a31bbc4556a59fd68fb6f722f32994c0896eb935d8946bd2c at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/design-decisions/references/devcontainer.txt

### Decision 006

`.agents/skills/design-decisions/references/index.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
9572d442689f1e836d42c42c6de3b9b3ce8cdf0b73f5206c320792c82566fbc5 at the reviewed revision and
56a676632f4b2c04b5a87d1f002b7f5c16a89e1f48db3060f3259ad7019dc06f at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/design-decisions/references/index.md

### Decision 007

`.agents/skills/design-decisions/references/network.txt` · `inapplicable`

This is the upstream agent ledger of Rust adapter and policy decisions. The changed implementation paths are
reviewed separately. Importing the upstream agent ledger would not change or validate Godot behavior. Old
archive member SHA-256 8e2b1323214a7a98b9216023738d0faf0bf6304a6a620646682a6bec42af3c7a and candidate
9c1292e5709e50d7bbb1240172b02c0e89ae3a8dc635d7f1db19d5c01aeff9e2.

### Decision 008

`.agents/skills/dev-pipeline/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
057163688655d4b7a355b8e5bd883aec5d18c4b1027e1b9baa25fe1913d050d1 at the reviewed revision and
cd56670c02242ffd21081a2257e4b2d7438bda8b51fc0cbeeb18faf73df50cc9 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/dev-pipeline/SKILL.md

### Decision 009

`.agents/skills/dst/references/fleet-search-roadmap.md` · `inapplicable`

This note records upstream organic coverage and measured search decisions for the Rust nightly fleet. The
Godot project qualifies its own fixture inventory and does not run or adopt these fleet configurations.
Pending Rust harness and simulation paths have their own decisions. Old archive member SHA-256
f4cef762a4feecb2b44d846c12e0653a53e717f04f6b935edf3612d8fd7b7d25 and candidate
d9012a6502adfb3d47df3475bd8ec9af48e38c726df8089d6a88868991770be5.

### Decision 010

`.agents/skills/ffi/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
abe6d025a92d7850104fbb9e0d6fdd33a89931837efc2d40c70aa28e82f544b1 at the reviewed revision and absent at the
candidate.
https://github.com/wallstop/fortress-rollback/blob/d124c89080004d96971a629bb0427056ee1805e3/.agents/skills/ffi/SKILL.md

### Decision 011

`.agents/skills/fortress-development/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
856adae02fdbbd748f351f58bb04cba5c30e4b8499bcad54e9bc728c05f82a6e at the reviewed revision and
ec0a31f7277904ffbd5999ae1f8dc62a133721cbec23014b97ba16b3a5d47e1d at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/fortress-development/SKILL.md

### Decision 012

`.agents/skills/fortress-development/assets/task-card.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are absent at the reviewed
revision and 6690aa3e9b9a266d34c65c850ccb246f5d070eca31786d381c0d7303aa30f0f5 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/fortress-development/assets/task-card.md

### Decision 013

`.agents/skills/investigation/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
7289d188bf61d155c28fe4a62cda7722577f4a47489025da6982eea1aeaa8edd at the reviewed revision and
5a8616bfaad5abacbd0b098521c45bd269d5b445cafde8abe83704434812eac5 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/investigation/SKILL.md

### Decision 014

`.agents/skills/kani/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
def3bb1df25e801c30c9bfa99559e5e741b0eb3ed9b0f7aaeac1b748baebcaa0 at the reviewed revision and
73b8a2260ae416a3a20b6c643a39973f9a1ce4cecb3ffb295643e20371274321 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/kani/SKILL.md

### Decision 015

`.agents/skills/kani/references/kani-obligations.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are absent at the reviewed
revision and 41e8c0536a227632df0d9e4f6d284748593d24b166e66e9b0100a6aa7601ec3e at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/kani/references/kani-obligations.md

### Decision 016

`.agents/skills/miri/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
9ca5c7ca411cd14d3ea8a09a98c4e5bfcc6267306bfc80d4da80962a1af9ce5f at the reviewed revision and
4d0ae8fe5aa4c0846111f8018ed3acfe0b068ebc4e02436f9b02aeb772b407f8 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/miri/SKILL.md

### Decision 017

`.agents/skills/no-std/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
5dee0c880dcc10da1cb71de4ce4129ce375bc248989fbc319bc38717c88adbf5 at the reviewed revision and absent at the
candidate.
https://github.com/wallstop/fortress-rollback/blob/d124c89080004d96971a629bb0427056ee1805e3/.agents/skills/no-std/SKILL.md

### Decision 018

`.agents/skills/review-readiness/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
ccf37a17fa5e7cbef9cc1f8f6aa987411a7b618358035e64f21ea6879402f13a at the reviewed revision and
0118de2df90221d7940fb9a6ab635d0dc8790b679eac5c60c5d0af8ddbde4b23 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/review-readiness/SKILL.md

### Decision 019

`.agents/skills/session-loop/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are absent at the reviewed
revision and 6606cdbd9dbc923c35fe5ea88e0675bfeac65396cfc36d2dbd13d8234095a014 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/session-loop/SKILL.md

### Decision 020

`.agents/skills/session-loop/assets/session-card.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are absent at the reviewed
revision and aa0fee3920b3c429cef8177ca0ba1ed16e78b3830655a31b5376ff1a443560cc at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/session-loop/assets/session-card.md

### Decision 021

`.agents/skills/testing/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
04843348e8918b2e5b22167b0928795bde9f4d437641640f4918fe2e9b4c212f at the reviewed revision and
090d80a7a86a1d26c8800e943fdbc680bdb2dde453c9ef104f45f88cdc0a3432 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/testing/SKILL.md

### Decision 022

`.agents/skills/verification/SKILL.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are
f05f189cba6ffb3f31bb1ae6c095e7c4a5c09e79d9bd5661811276c4f44521d8 at the reviewed revision and
72bcdd9ad17668930388d877db4b951545475adf313795a3dd5daea3f23d04fd at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/verification/SKILL.md

### Decision 023

`.agents/skills/verification/references/model-impact.md` · `inapplicable`

Upstream coding-agent guidance or support material. This checkout resolves its own agent entry point and skill
index via AGENTS.md and .llm/context.md. Compared archive member SHA-256 values are absent at the reviewed
revision and 669cbdd6de2bc10e2bacd25e0b70c3bdc8cf51e7dc97194cbaa6393071146ce7 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.agents/skills/verification/references/model-impact.md

### Decision 024

`.cargo/config.toml` · `inapplicable`

The diff changes the t, qt and ci nextest aliases and adds tf and tfull. The Godot reference runner invokes
explicit cargo test arguments and uses none of those aliases. See scripts/reference/run.py. Compared archive
member SHA-256 values are 67e60d7d2663c13253df32950772c4f9592a55e6874b18b6cc118dd6fbba0b5c at the reviewed
revision and 8cd03803a0012ee590b285630287f515e4f419ff1ca448220ca9e0b7458c7da2 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.cargo/config.toml

### Decision 025

`.cargo/mutants.toml` · `inapplicable`

This config drives the upstream cargo-mutants job. The selected reference runner invokes explicit cargo test
commands and publishes independent Godot mutation controls. See scripts/reference/run.py and
scripts/oracle/parallel_launchers.py. Compared archive member SHA-256 values are
eb2fd190ff27438b0ebe4fcf38c78724a7dff07572751fcadda4d03d26983467 at the reviewed revision and
757676b5f251975ce326d76b004d3e987dd071e1d4be46b85e423a60de43b107 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.cargo/mutants.toml

### Decision 026

`.codex/config.toml` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
3f0f7c9a22e13e02f26bd77a8c649b240ed16ef841e3589b2b79e796afd7ed18 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.codex/config.toml

### Decision 027

`.config/nextest.toml` · `inapplicable`

This config selects upstream nextest profiles. The selected Godot reference runner executes cargo test
directly. See scripts/reference/run.py. Compared archive member SHA-256 values are
b191eaa35cf216e1cfd1b8a7c3e9a6529e484665c3a0f4bab0973aca459086db at the reviewed revision and
7121c3d5f6661f83e2cbd3b089dbfdf783204319730cb81ec7750f0f95495e9e at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.config/nextest.toml

### Decision 028

`.cursorrules` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are df33cea86cf3b9dfb5557a8c5f41c8a7ac74da4a4e1dc6bc8b25962b0a15daf7 at the
reviewed revision and 57466c7c784d7c141762ac7d488beea0ace8d50ac21e66f0d8da70403a829e5f at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.cursorrules

### Decision 029

`.devcontainer/AGENTS.md` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
1a4a1de0fc32718629588e820c13de5365c4b9f5b397f2cfcfcdb6737c9909c6 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/AGENTS.md

### Decision 030

`.devcontainer/Dockerfile` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are 1442ec6673ea777ac13d62370eaefc23045488bbf0665fc9d89077630fc6ae9c at the
reviewed revision and 2a344e54b36e2adcb5b908ffc5eb275a9d03577a4d81c5aad2c2cda77aaed93b at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/Dockerfile

### Decision 031

`.devcontainer/README.md` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are 615aa832d015eff73f843176b6b1075891793cd9fd9ea9d6e2d1d14f84ba5b47 at the
reviewed revision and b7dadf446d64b1f3bc8dd9fe722356a21fde8317c0c43298bdae6983c928ecd0 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/README.md

### Decision 032

`.devcontainer/ai-backends.sh` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
700fc138793707c3ff4f59d417440392866bc8c4490673853ad9d23018b4aadb at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/ai-backends.sh

### Decision 033

`.devcontainer/check-mcp-env.sh` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
43b57b852f8147cf76e3d61a4d12b114fff451660d5ae68ea5f912c499ba3e68 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/check-mcp-env.sh

### Decision 034

`.devcontainer/check-mcp-health.sh` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
781eb41bc5eae198efbdefac4a779e2fdaa7cd7db889788968c7d4ade32362b3 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/check-mcp-health.sh

### Decision 035

`.devcontainer/claude-zai.mcp.json` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
6ac39ef89019b514ddf65270b532294146e0b744302ad2564782c656aea25726 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/claude-zai.mcp.json

### Decision 036

`.devcontainer/devcontainer-bootstrap.sh` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are 30a2f0f0c4a02fc14bced5d46322a9f192f886c11ced7d2083fea41a4a7171a7 at the
reviewed revision and f12951a0f2d584b1f95d6706976292e7e1eec8593c4a60840c5a6cfc7f94f955 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/devcontainer-bootstrap.sh

### Decision 037

`.devcontainer/devcontainer-lock.json` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are 95071e5ffb64981cc24aceb231a24b1667c0dc16c7fa28de9f631af799ccb86e at the
reviewed revision and cd959bdbfb327f2eb96c8f54028945b86100accf474690307e8868ce20b7880d at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/devcontainer-lock.json

### Decision 038

`.devcontainer/devcontainer.json` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are 9b1df74eb49c86ac47c47c33b06cfeed9b7f11fe5fa6fb6520eb8ee6d38de213 at the
reviewed revision and eb0c0815f7b732c59a241bc72b7994ef1ff540418e75034b69dc8e8d65553964 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/devcontainer.json

### Decision 039

`.devcontainer/welcome.sh` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are aa66aa0a310bcc3fbee632add5c95d8eb9f5d4806a6d962c9d6da0cb07384be5 at the
reviewed revision and 995a889d34204434613eb8be65b55584ea63267240d9b60807deaea1f97a8591 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/welcome.sh

### Decision 040

`.devcontainer/zai-mcp-remote.sh` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
a37de51d47805b97ed5fff58af26a15e87fd281b2fc540d68a9ad902580183f4 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/zai-mcp-remote.sh

### Decision 041

`.devcontainer/zai-mcp-vision.sh` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
b71905e7246b25c9b99ad3c7be1a8928a7635e89b45db77d705d806d33e26e7d at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.devcontainer/zai-mcp-vision.sh

### Decision 042

`.dockerignore` · `inapplicable`

These exclusions apply when building the source project’s Docker image. This checkout builds its own container
from .devcontainer/Dockerfile and verifies the selected source archive separately. See
.github/workflows/devcontainer.yml. Compared archive member SHA-256 values are
f8369d0c179530dc4d2d8d34c5f9cf8a319dcd72ff1efa74ce7aa13872a37596 at the reviewed revision and
4d9d9009f6d80e7493811ba742cbc843efb400a7addc7e5403ab59b6efa539ba at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.dockerignore

### Decision 043

`.env.local.example` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
a32bb9107b99d9d7991904e1030d18887ebcb1d10504e7b95b8a25114ef3f354 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.env.local.example

### Decision 044

`.github/FEATURE-COVERAGE.md` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. This checkout’s Gate and Reference Baseline
run from .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Nested source workflows are
archived content. Compared archive member SHA-256 values are absent at the reviewed revision and
0ffb9e3d03d7685ab297f37d2bad85dc61261b0b4f2af313cfb6013c087a9ba0 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/FEATURE-COVERAGE.md

### Decision 045

`.github/PULL_REQUEST_TEMPLATE.md` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. This checkout’s Gate and Reference Baseline
run from .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Nested source workflows are
archived content. Compared archive member SHA-256 values are
78b103bd350e3a21457ee47c951a2e28c3c0dbd035862c894728133a8a76ec60 at the reviewed revision and
fc9bd18f0919ca430f8c76084df63c270bd39ac17ec77dfd170cd42216a4fb88 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/PULL_REQUEST_TEMPLATE.md

### Decision 046

`.github/actions/install-cargo-tool/action.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named
Install Cargo Tool. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are e676bd499322d98476e1e9666ea6ceaa3dafd0a7a53d0ea5fa51c1a709f58b8f at the reviewed
revision and 492a9ab0ad8d1d3c9321c489dc1d87e511fc6692971fc5da68525193554c518d at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/actions/install-cargo-tool/action.yml

### Decision 047

`.github/actions/setup-kani/action.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named Setup
Kani. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are absent at the reviewed revision and
4a1c7f68fc48150b4f4c9623e1a3c40b52826b26a7f82e1e8b5bee6119cd4082 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/actions/setup-kani/action.yml

### Decision 048

`.github/copilot-instructions.md` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. This checkout’s Gate and Reference Baseline
run from .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Nested source workflows are
archived content. Compared archive member SHA-256 values are
3cf71f3042b5a5316d55156f12982cc6b7921bf56dbc8158482b633badb83df5 at the reviewed revision and
9ea6751b4d026b44f8676e0b7fb13fc187a37377bc704650ab591fe3e5c560eb at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/copilot-instructions.md

### Decision 049

`.github/dependabot.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. This checkout’s Gate and Reference Baseline
run from .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Nested source workflows are
archived content. Compared archive member SHA-256 values are
6f70a0c11ce3d091aaa312c66f2798b0f16e3883721b9fe2dd61634bad5d10c7 at the reviewed revision and
6dad356ec7b448a2245c62eb440197a32495055a790930b9dbaeb3bab4ec18b0 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/dependabot.yml

### Decision 050

`.github/rulesets/README.md` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. This checkout’s Gate and Reference Baseline
run from .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Nested source workflows are
archived content. Compared archive member SHA-256 values are absent at the reviewed revision and
d86520550314a3b23e461eecdc79cd8c60204a5384860a2645791906b6553c0b at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/rulesets/README.md

### Decision 051

`.github/rulesets/main-protection.json` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. This checkout’s Gate and Reference Baseline
run from .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Nested source workflows are
archived content. Compared archive member SHA-256 values are
81432c41975131cbe71d7944b356b6969d3bb8ec4098e2c70c978aaff37486e7 at the reviewed revision and
0a88c59549b5a405dc2b3f89aba3e9e8a50a62fd1e06f631ff0cf568f0b6d409 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/rulesets/main-protection.json

### Decision 052

`.github/rulesets/merge-queue.json` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. This checkout’s Gate and Reference Baseline
run from .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Nested source workflows are
archived content. Compared archive member SHA-256 values are absent at the reviewed revision and
adadfef564f8e416ed7c9389a4f9972091f613f1ec92a881c07e2e804ec3174f at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/rulesets/merge-queue.json

### Decision 053

`.github/workflows/agent-metrics.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named Agent
Metrics. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are absent at the reviewed revision and
ec43c98762b019d7fb06d73ac6a035b843be769ff8574ce39d299d033445b62c at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/agent-metrics.yml

### Decision 054

`.github/workflows/ci-agent-skills.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named Agent
Skills Lint. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are f925a5c5007c5d497b2dfc03cfcbfd5a3d81ab3b752521f3d996ced433fc1db7 at the reviewed
revision and 4956ae77f920748a796260c83d74b1506a2333474fc51d0ad6be9eb1425c0b35 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-agent-skills.yml

### Decision 055

`.github/workflows/ci-benchmarks.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Benchmarks. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are a4c48514359a4993851a408df992797053d818d23bb38491db8657eccc062484 at the reviewed
revision and bf3b0914be544c35a63ea7a76195b7f85f5bfaba1546c1f673205981655c3ff8 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-benchmarks.yml

### Decision 056

`.github/workflows/ci-codeql.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
CodeQL. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 0e26c07d1b495e2a5b9cc593382b444357c68a07a624dcf2e0afb410fe34a797 at the reviewed
revision and 52f00c55e88e6f4f4d70a58b3cc43734d6514e788bdb8dbabe3f094831355090 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-codeql.yml

### Decision 057

`.github/workflows/ci-coverage.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Coverage. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 08bd0080cb661486b7f27b004c83da8b2df3bb74a8f0d2fdd4d33a5779f691bf at the reviewed
revision and ad355a044320b6c1560810ed7a0a8d0ada7c791676184d261f9c9ca97c2ffc1e at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-coverage.yml

### Decision 058

`.github/workflows/ci-docs.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Documentation. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 193495ed2a14050c9888e9ce5dac821c9648dfee4816a4114473502560df8a19 at the reviewed
revision and b8a4b272339943e152cfb5a8ba1751b62f471aff66823de05bab9a8d9d24a5f6 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-docs.yml

### Decision 059

`.github/workflows/ci-fuzz-nightly.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Fuzz Corpus (Nightly). This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are absent at the reviewed revision and
3bd0c9ecce6c6dd0333c505f5b8f6cdb6c64768ad04fe6089d434fbc3e00dea1 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-fuzz-nightly.yml

### Decision 060

`.github/workflows/ci-lint.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Lint. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 55ce4e35e89ffa2704fc739afafe080ab5589eec353abeb5fcb36d8fb7707746 at the reviewed
revision and c5494fe8b1b548803a12822064d1a88c147d552a1b1e12078c4881ccc3da6c8f at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-lint.yml

### Decision 061

`.github/workflows/ci-metrics.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Metrics. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are absent at the reviewed revision and
0ce9cb9e832c10be88d722c524cb3af995042e8adf996a152a6aca1fe4f69300 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-metrics.yml

### Decision 062

`.github/workflows/ci-mutation.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Mutation Testing. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are f612a4bd74dc02e43b7374a88fb9110be5f44ae97632a78b54941186542ec812 at the reviewed
revision and 5a6faa42072f1bfcfc3617b890556a28b78848d1e6992181e5a58a022f554352 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-mutation.yml

### Decision 063

`.github/workflows/ci-network-nightly.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Network Tests (Nightly). This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 3fc2a65c618cc5588e8cf465ecc47509215cf29d81a94a4d8a79ca6710846678 at the reviewed
revision and a85f82e0ac57db9d8ddf5124f032495c07135576b63337d2c5738f47083f5413 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-network-nightly.yml

### Decision 064

`.github/workflows/ci-network.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Network Tests. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are efa1f2554900ed21afcf6c34af97105f8f545eef18a155e209fedf80570c8a97 at the reviewed
revision and b6946890e3314ffd31072f2d4d7ad346373be06f4c9d9687e45f41bf30ccf4c7 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-network.yml

### Decision 065

`.github/workflows/ci-pr.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
PR Gate. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are absent at the reviewed revision and
0d803d825df416196c30a9177caa0a41c483759e0534e8a300f83d2149bdf4bf at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-pr.yml

### Decision 066

`.github/workflows/ci-quality.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Code Quality. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 77a2abbd23b9d60675ae9c0dbb5adf00977b4d4289a5e4b03134cc89c08caaf5 at the reviewed
revision and f6d11a9fef8d738ccefe5ea7e6edb633821c7488702c8d139a75fc5be9043b7b at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-quality.yml

### Decision 067

`.github/workflows/ci-release-state.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Release State. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are a38d6c9f9cc9febf77ea205eacdd284623a04a88ceba86f6c1e0b70c74f4fc29 at the reviewed
revision and d0b328359ae29a9333fdb990ed6d58bfc9d0c2f1d15ae217fbb76d02eef130a5 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-release-state.yml

### Decision 068

`.github/workflows/ci-rust.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Rust. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are b144f7663a4d2f4f10525266fb24e2fcd899cb7c025a1161026739d7f2be7d37 at the reviewed
revision and f5b51258a72c8d6843d2b4f1a176f87d6081e7542ff8cfe2441a6c29138b93b7 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-rust.yml

### Decision 069

`.github/workflows/ci-safety.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Safety & Correctness. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 776f7e1c5292b9c0df7c964a665f1aa1d073788cbd68b88c1fe0b79726f4fe93 at the reviewed
revision and 56e5c81af21b7ddfdf91cfd2a2dfb6dbacda1254ea1a1dc60f828de72f6db005 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-safety.yml

### Decision 070

`.github/workflows/ci-security.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Security. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 68caa1e4f15c59224ff0e5d7578505c35b92c27f485998148a3b1ac16fac894e at the reviewed
revision and 4a288074f485eabf6dfa1a94643e05499b69c5387e79a6f920467493dff81e4d at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-security.yml

### Decision 071

`.github/workflows/ci-simulation-nightly.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Simulation Tests (Nightly). This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml
and .github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 2ab2de6d3667b336493585ecacc177f392985cc91cdd25472d0d16f57a070e81 at the reviewed
revision and 2d442da59830d18492d53aa2f1cd843ea0153ca6a0e9eaf372120b1796b31718 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-simulation-nightly.yml

### Decision 072

`.github/workflows/ci-verification.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Verification. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are f628606ff8d1711c0e66c4e4b76e4098d23ec2e0623b7908dbfe17c44d028091 at the reviewed
revision and d7ee8365a19d516652466c49049956a7ad2fcb94d0d4f581ad430227f503e74b at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-verification.yml

### Decision 073

`.github/workflows/ci-version-sync.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named CI -
Version Sync. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 6f99f8b6a742f733eac661485454f55fd96e25065a7771757410a9aa377cd837 at the reviewed
revision and e725a2a91c4257f1c75788e2a0ae31756ae348dc78e2b07a5cc6c9c3facbbbb8 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/ci-version-sync.yml

### Decision 074

`.github/workflows/devcontainer-build.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named Build
DevContainer Image. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 78ade320c6ce19eec35155c2a043561b518a4dc9f3760289bf2eefe260960440 at the reviewed
revision and 9484276dba108d5291970646422a02f7347ff4192834fce3877a564dc9861d3a at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/devcontainer-build.yml

### Decision 075

`.github/workflows/openai-review.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named OpenAI
Review. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are absent at the reviewed revision and
de99bbe5eeb13b6e977bcada9eb98760842d13812f2311e00efee7a82d39cff6 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/openai-review.yml

### Decision 076

`.github/workflows/publish.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named
Release - Publish Crate. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are 032585eeaf6b6d90a062167ea55ec6797160f88bf18a51623d0b782daf839bd1 at the reviewed
revision and 2aea08dfcac23e2c61d76239b42e8105911f206f77ee78f4e711713016e64db5 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/publish.yml

### Decision 077

`.github/workflows/release-prepare.yml` · `inapplicable`

Repository-owned configuration from the upstream GitHub project. The source workflow or action is named
Release - Prepare PR. This checkout’s Gate and Reference Baseline run from .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Nested source workflows are archived content. Compared archive
member SHA-256 values are f308354b3fcc4577ee053079c9b94e7cd97d973199e369c67630080b98c09bf6 at the reviewed
revision and 28e79c90f725a77d274902d0ca4ac572f46e0143bca48e53086eceeeb8898bf8 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.github/workflows/release-prepare.yml

### Decision 078

`.gitignore` · `inapplicable`

The upstream diff adjusts root editor MCP credential/output conventions and mutation output patterns. The
archive is verified as source input and its Git ignore policy has no effect on this checkout. See
scripts/reference/fetch.py and the local .gitignore. Compared archive member SHA-256 values are
904b7280361b6cff841e56e1a00fb773cdb5e0206e7debfbe644d6f93aa7a8ca at the reviewed revision and
3bae9bb4c27cfe5097cf3ff1e7b2454c47085b75bd026c3eb2638317e9224665 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.gitignore

### Decision 079

`.kani-version` · `inapplicable`

Pins the source-project Kani runner. The Godot reference uses separately pinned Rust and Java tools with
scoped models. See docs/reference/pins.json and .github/workflows/nightly.yml. Compared archive member SHA-256
values are absent at the reviewed revision and
a6fcc5d96eed4f7ab817b3efc0da1f6ef4e1e736e7aa83361a66f2b965ccdb1e at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.kani-version

### Decision 080

`.mcp.json` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
328326079159e37aa4be9327cf8d23ec7187ae62a28fb8bad4b567816cb9011d at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.mcp.json

### Decision 081

`.opencode/plugins/bounded-network-retries.js` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
5d572c586e1453d28c2d30256107a30bc821da42116924f7fc57c5e2938d174e at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.opencode/plugins/bounded-network-retries.js

### Decision 082

`.opencode/plugins/lib/session-budget-core.mjs` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
ccddc821e8f0ab19a3993b7025e39cf4fd3ce44f82c93715d7c63d0dd918f32f at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.opencode/plugins/lib/session-budget-core.mjs

### Decision 083

`.opencode/plugins/lib/session-budget-core.test.mjs` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
c383089dcb03eb983668bfce719a5b9d76dda99c693cdd314b7d4b404c8f3969 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.opencode/plugins/lib/session-budget-core.test.mjs

### Decision 084

`.opencode/plugins/lib/session-budget-lock.mjs` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
b2643fbaef6941d569696d6758a81952552e8df28e54a2e7e7cd10ca27b1b2df at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.opencode/plugins/lib/session-budget-lock.mjs

### Decision 085

`.opencode/plugins/lib/session-budget-lock.test.mjs` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
0b8924d4e945154dde5d15a866ce425cff4e510abdd4bff02ae8a5c41ed98172 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.opencode/plugins/lib/session-budget-lock.test.mjs

### Decision 086

`.opencode/plugins/session-budget.js` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
75c03bb8519e6312eabeddda36927f98e4f88b9f186ef5bcc5e5132c461f29fa at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.opencode/plugins/session-budget.js

### Decision 087

`.typos.toml` · `inapplicable`

The upstream crate’s typos dictionary services its own lint workflow. This checkout applies its own
source-width and harness checks. See .github/workflows/gate.yml. Compared archive member SHA-256 values are
aa578f446c5b90acde384b9abc72a05893967400affa9e93f965ed6f40b93757 at the reviewed revision and
b372595822de7dbc3bc72837c643c4870fbff5a50754967580921dee63fcb80f at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.typos.toml

### Decision 088

`.vscode/mcp.json` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
1eed042446ea2fe6d0b8e5e9936df76811e059806a1cfa4e68baf77ee561fe5f at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/.vscode/mcp.json

### Decision 089

`AGENTS.md` · `inapplicable`

This file records source-checkout agent instructions. The Godot repository owns those processes through
.llm/context.md and .github/workflows/gate.yml. Compared archive member SHA-256 values are
c60eddce6f5bda9d1705dc15a3d3b6dda6245a47803783802849bde6c148f632 at the reviewed revision and
3286e1a22200f6ee13a858a9bfc098f295371e5532508b8332c103ed67a4738a at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/AGENTS.md

### Decision 090

`CHANGELOG.md` · `intentional_divergence`

This is the source 0.14 Rust release narrative, including new APIs/macros and adapter metrics, source-only
v3-v6 wire transitions, Rust ownership/storage and dependency changes, and corrected removal, checksum,
spectator, hot-join and replay behavior. Godot CHANGELOG.md, docs/supported.md, docs/peer-lifecycle.md and
docs/oracle-replay.md own the product-facing changes and explicit compatibility choices. The per-path source
decisions and qualification receipts record behavior changes at their owners. Representative executable
evidence includes corrected final replay of 257 rows, both decoded withheld prefixes of 256 and 255, the
candidate coordinator-only scope difference, and native package qualification. The optional Rust packages link
the exact candidate; the Rust release narrative does not become the Godot release inventory. The candidate
archive passed 67 P2P scenarios and the source-selected formal handshake and spectator checks on both Godot
editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929 Candidate
package qualification has 12 digest-verified platform/editor results, 32 canonical 40-row matches and 32
restore/encoding controls.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492 Reviewed archive
member SHA-256 5fa0bd5c5687cb8c05cbd8311bafe29d32fb9e9672a355d36294f8a85cdd551b and candidate
07d5ce7cc21cacbb9656bd6f68ce656da76cd92d4e9e54f19e6f68e8a46384ac.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/CHANGELOG.md

### Decision 091

`CLAUDE.md` · `inapplicable`

This file records source-checkout Claude instructions. The Godot repository owns those processes through
.llm/context.md and .github/workflows/gate.yml. Compared archive member SHA-256 values are
57a87640a47647eef98e837061913679a43cd768b36cd6c04df7b3d97097fa5d at the reviewed revision and
46621613dd3b565aa3dd1c5783e6d2e6224b43cfdb712130a0523a5f89e79706 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/CLAUDE.md

### Decision 092

`Cargo.lock` · `intentional_divergence`

The source workspace lock moves from 158 to 155 package/version entries, including the added portable replay
fixture and changed Proptest, Tokio, Wasm and Z3 tool dependencies. The unchanged top-level crate version
authenticates nothing on its own. The candidate lock is part of the verified archive and its exact digest is
stored as the upstream reference lock. The Godot extension and oracle independently resolve their smaller
--locked graphs. They retain own versions for common transitive crates, so upstream workspace lock replacement
would alter the Godot qualification inputs. The candidate no-default-features Rust library run reported 2,103
passed, 0 failed, log SHA-256 1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Candidate
package qualification has 12 digest-verified platform/editor results, 32 canonical 40-row matches and 32
restore/encoding controls.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492 Source-revision Rust
workflow https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046809665. Reviewed archive
member SHA-256 7ca0a14b1c9ba068b72f02324f28d3a07df8fb464258a7b9bc3eada53ee57679 and candidate
2643529601aab0a25302bf8455b40ee352cd00576cc85c75256af22470e1caef.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/Cargo.lock

### Decision 093

`Cargo.toml` · `intentional_divergence`

The source adds the replay fixture workspace member, disabled-by-default exercise hooks, a non-Wasm Tokio
dependency boundary and a Proptest dev constraint. The Godot oracle and optional extension are independent
Cargo roots, using the archive package with default features disabled and their own locks. The locked
extension Web feature graph contains neither Tokio nor either new source exercise hook and the workspace
fixture is not linked by the oracle. Observed Web graph SHA-256
bac911b863e2889b606576df77ccbe40a05c010e06562a5413ac9713c23ea5a3. Candidate package qualification has 12
digest-verified platform/editor results, 32 canonical 40-row matches and 32 restore/encoding controls.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492 Source-revision Rust
workflow https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046809665. Reviewed archive
member SHA-256 cb127fc3812b50637599ad259a99016468f038e10c0af9e90818253d3b42f40d and candidate
40538661cd5ae696bd4045672f92cabfd304db53b5258e3263c0e635041aed41.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/Cargo.toml

### Decision 094

`PLAN.md` · `inapplicable`

This file records source-project maintenance and planning rules. The Godot repository owns those processes
through .llm/context.md and .github/workflows/gate.yml. Compared archive member SHA-256 values are absent at
the reviewed revision and 2c91a9c9a166bce28735c929013c2a4e8505c2a2be24679b34b340f544192533 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/PLAN.md

### Decision 095

`README.md` · `inapplicable`

The entire hunk adds upstream developer feedback tiers built around Cargo nextest, Kani and its required CI
Gate. Godot uses make gate and the local .github/workflows/gate.yml and reference-baseline.yml. Archive member
SHA-256 reviewed 416975e838fc42fd9941935658fddf6aa662ec680dfb4f985e8cef37d3033907, candidate
f9b4e01a759073ad8d273ee1e549098c4a5613b49eed87407fa5d2508e71a76c.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/README.md

### Decision 096

`benches/h16p_mesh.rs` · `intentional_divergence`

Adds a warmed full-mesh advance-frame wall-clock benchmark for 8 and 16 Rust peers. Supported Godot sessions
cap the fixed roster at eight; experiments/gdextension/benchmark.py compares timed 2/8-player synchronous
rollback steps against independent canonical bytes. The 8-peer mesh case has functional observation in the
native and P2P rooms. That evidence and the distinct workload in docs/experiments/upstream-binding.md give no
equivalence claim for the upstream full-mesh median budget. Compared archive member SHA-256 values are
445b2c26a03912bbbdc0735daae6469a46a30eb27610eff85b62bd6104776d56 and
354ec13f3d85b67d739e78679fc72b0fb370a98d0d6907df47c50ed28cd76733.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/benches/h16p_mesh.rs

### Decision 097

`docs/api/public-api-snapshot.tsv` · `inapplicable`

The changed file is the upstream Rust item inventory, including prelude aliases, hidden diagnostics, two
socket-metric APIs and the recovery method. The upstream docs/api/public-api-census.md identifies it as the
release semver baseline. Godot exposes a separately documented driver, callback, and native packet boundary
through docs/contracts.md, docs/native-backend-migration.md and experiments/gdextension/src/peer.rs. The
inventory is not a Godot API artifact. Behavior named in the added Rust entries has its own path review.
Archive member SHA-256 reviewed 0944cd958725088f1acd3c9c439e559f5c23dd904c7154c92620e226d42e1bdc, candidate
80dd4869c70f83fe1a731c9f9c9abc8c0211d241ebb91e0ca8c4ca3842512dfd.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/api/public-api-snapshot.tsv

### Decision 098

`docs/contributing.md` · `inapplicable`

This file records source contribution and emergency review procedures. The Godot repository owns those
processes through .llm/context.md and .github/workflows/gate.yml. Compared archive member SHA-256 values are
25c05781837b1ade9bb732ffd8b10d1b64b698c887f961bb71f535b120d76549 at the reviewed revision and
5f513da9b6de97f1dca703c7d7961c497ee1d86d66c313c22e7916eec5db3bb8 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/contributing.md

### Decision 099

`docs/getting-started.md` · `ported`

The upstream example aborts request processing when saved state is unavailable or a required checksum cannot
be produced. Godot uses typed callback completion instead of a Rust macro. tests/unit/test_driver.gd covers
failed callbacks and unavailable rollback history; tests/unit/test_snapshot_history.gd rejects failed saves
and absent or malformed checksums. docs/native-backend-migration.md defines the same first-failure stop for
the native driver. Archive member SHA-256 reviewed
67df73eda278a285ab25699a77caeaac93318316cc0e0fb9bac3533d16206eac, candidate
00e308cf6af816f2f90cf81b2c2f5cde022d1e4170ae7fdb8dfde3cbb05f1cc7.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/getting-started.md

### Decision 100

`docs/migration.md` · `intentional_divergence`

The Rust migration adds a terminal spectator error, bounded hot-join retry, v3-v6 source wire transitions, and
the exercise-census feature. Godot migration follows its own engine and protocol guides: authenticated clean
spectator finishes drain the tail while known source loss fences playback; the fixed roster excludes hot join
and transparent reconnect; GDScript peer wire and optional Rust room versions are independently negotiated.
The source-selected receivers exercised both current protocol selection and incompatible source/field refusal,
and the native profile rehearsal supplied matching package evidence. The candidate archive passed 67 P2P
scenarios and the source-selected formal handshake and spectator checks on both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929 Candidate
package qualification has 12 digest-verified platform/editor results, 32 canonical 40-row matches and 32
restore/encoding controls.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492 Reviewed archive
member SHA-256 83bd8ac05725c7413352233bfc67e11958ee68fedd783f927a6ed811f5ff0800 and candidate
991d2f8a8f0c5f13a40bb80c60cbf998427d790740113259061008e88725c2d4.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/migration.md

### Decision 101

`docs/production-checklist.md` · `intentional_divergence`

The upstream release checklist ties its checked-in 4,096-frame portable replay, socket acceptance counters,
strict Rust build and extended mixed-transport corpus, browser suspension probes and Rust misuse examples to
the upstream release. The exact upstream WASI lane printed 4,096 frames, 8,192 requests and both fixture
digests; bare browser passed 12 tests, and the Emscripten job ran three tests. Godot release conditions use
the independent addon policy in docs/verification-policy.md, the status-aware reader and final-state checksum
of docs/oracle-replay.md, and the named profiles in docs/reference/p2p-profiles.md. The tested native rooms
are a separate 40-row interoperability claim. No inference about the source mixed-transport throughput or
Godot background-tab release coverage is made from it. Source-revision Rust workflow
https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046809665. Candidate package
qualification has 12 digest-verified platform/editor results, 32 canonical 40-row matches and 32
restore/encoding controls.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492 Reviewed archive
member SHA-256 85ea67285afbf74eb02de26b09af88e34f1666ee97c6e83a2696aa1bb6edc9f9 and candidate
cc9b2e465579d6f5e67a3fb59426dace83aad25a84eb3897801fbd3366831416.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/production-checklist.md

### Decision 102

`docs/reconnect-playbook.md` · `intentional_divergence`

The upstream playbook defines automatic strict-majority and witness admission, the explicit Rust removal and
synchronization paths, an isolated-side one-way terminal tail bounded by prediction+1, and a rejected
acknowledgement-floor experiment. Godot's automatic timeout matches the agreed-majority rule and its own
witnessed-cut contract in docs/peer-lifecycle.md. Its callable surface keeps the explicit Goodbye fence and
excludes transparent reconnect (docs/supported.md#explicit-exclusions). A scratch deterministic production
Godot peer probe used the same fixture with and without the target's outbound traffic. Both editor pins
repeated the same result: target still received 66 addressed packets, peaked at confirmed frame 12, terminated
for missing_quorum, and the survivors committed cut 5 with identical canonical callback states through
confirmed frame 65. The observed 7-frame tail fits the window-8 plus one bound in this schedule. The connected
control had no cut, and all peers agreed through confirmed frame 84. The source policy's acknowledgement-floor
performance measurements remain source-only. Probe SHA-256
2628dc78e75006d67e17baa285daf89918d07b1ff3f16e244f813b922b682310; fresh-run log digests
4ff11d8e8735f8b32a94f4e02cf42d711860eb2e7024048424d145728c5a568d,
4ff11d8e8735f8b32a94f4e02cf42d711860eb2e7024048424d145728c5a568d,
941e3a3fca28882c08a3f43e312811fbe1b4b863a1db2fefa20f9c0184be94a9,
941e3a3fca28882c08a3f43e312811fbe1b4b863a1db2fefa20f9c0184be94a9. Reviewed archive member SHA-256
8520ef75cd847243419a85256748e3b9519a1705b49d12cffa4b435a7b7d4952 and candidate
3b82670564d4788641a8348451f52c65cbe670f564b90d628aa8e1cf872e63a1.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/reconnect-playbook.md

### Decision 103

`docs/replay.md` · `ported`

The upstream addition documents confirmed-input service after local sampling stops.
docs/oracle-replay.md#asymmetric-delivery-and-final-recovery documents the selected source and Godot
Driver.recover contract, including re-simulation at boundary 257, idempotent repeat, original confirmed
export, and withholding both final rows. docs/integration.md documents the separate Godot terminal checksum
capture. The upstream examples use Rust replay serialization; Godot continues to use FRRP versions 4, 5 and 6.
Corrected candidate exports are 257/257 without replay desync; historical asymmetric exports are 256/255 with
128/170 replay desync events. Verified paired replay receipt SHA-256 values: 4.3 candidate
ef58d9c9eb8a50b8576a60db0cb4f5a2a49b0c55adb6d62afef9f9fc6b5f29d7, 4.3 historical
c0bcf1ae4dc2dfabb633af5f5dfc4d4324fa77bc9e8fde224f8a8f9ec7e0756b, 4.7.2 candidate
62a9a153a8fb3d17f086c4ed7523e73b72b8d983cd2eef49d8b5294ae3cb68f6, 4.7.2 historical
0447e717a67380975c8bc040be21d3490c8bf115d24d2e66bf3b5de401b812e4. Historical archive member SHA-256
a298e64c31a13d39b93c03250b1ae1baee80fb6f87b442177f1527fd05d91344. Candidate archive member SHA-256
d08bf1a2ecf8f57af885109e5afcece5b893c76716d5c5463ea829ffde6333c0.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/replay.md

### Decision 104

`docs/specs/README.md` · `inapplicable`

The single added row links to the upstream consensus design paper. Godot operators use docs/peer-lifecycle.md
for the supported barrier and docs/oracle-p2p.md for the measured fallback boundary. The index itself adds no
runtime claim. Archive member SHA-256 reviewed
f88d3479f0d42eab13d797f52ae2733565974e82e73abdcdf2ccf3ed493922dc, candidate
b51645e6973643d6d070dc66d6bfaa6a9b884cfee94fb8d6b64d4e54ef3852d2.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/specs/README.md

### Decision 105

`docs/specs/api-contracts.md` · `intentional_divergence`

The upstream API now describes automatic strict-majority/witness admission, Rust explicit removal with
source-epoch, provisional Ready, retry, abort and fallback rules, and zero-speed terminal spectator drain.
Godot documents the matching automatic witness and protection of the agreed cut while retaining its own
authority and all-survivor certificate, an era/roster-bound operation identity, a conservative timeout on
coordinator loss, and a positive catch-up speed with clean END distinct from selected host loss. The port does
not expose the Rust remove_player or zero-speed APIs. Scope and observed behavior are in
docs/peer-lifecycle.md, docs/oracle-p2p.md and docs/spectators.md. The candidate ordinary drop receipt SHA-256
is f9d1d94c89c0e44162cc9eb7dd1a8802f600549b161d2e00c4a9645ee6a2b58c, and the isolated failover receipt SHA-256
is 805352d06bfd6119d124d8a2ce03fea55964a5392974b3449a42b256be4a2cd1. The candidate archive passed 67 P2P
scenarios and the source-selected formal handshake and spectator checks on both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929 Reviewed
archive member SHA-256 fb45d8d830f3847af2f589d251007f4ffe32d22a6c43c90899fb468603bd84f8 and candidate
9db48d5a3efc789036300768c0e848ec8de07bc371d096b1f6eb0b9bd2712edf.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/specs/api-contracts.md

### Decision 106

`docs/specs/consensus-posture.md` · `intentional_divergence`

The source rationale chooses deterministic membership certification with strict-majority, agreed participants,
fallback authority and terminal-epoch fencing. Godot shares the confirmed-prefix and partition safety goals
using its frozen roster, all-survivor certification and terminal timeout. The candidate coordinator-silence
comparison in docs/oracle-p2p.md reproduces the liveness difference, and docs/peer-lifecycle.md covers local
quorum refusal. The optional native boundary does not expose a coordinated-drop guarantee, per
docs/native-backend-migration.md. Archive member SHA-256 reviewed absent, candidate
9e72411e637003b313d43c22ed04fa14c9da16e163953db58982fb23023fcf80.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/specs/consensus-posture.md

### Decision 107

`docs/specs/determinism-model.md` · `intentional_divergence`

The source documentation replaces generic portability advice with checks on the Rust replay format,
pointer-width serialization and hashing, and exact Rust fault-schedule digests. Godot’s canonical byte and
checksum contract is independent, with explicit little-endian integer handling in
docs/experiments/integer-encoding.md, exact snapshot/checksum width in docs/contracts.md, and its own replay
fixture/interface and profile receipts in docs/oracle-replay.md and docs/reference/p2p-profiles.md. Exact
candidate native fixture tests passed 7/7 and exact source stress-corpus tests passed 11/11. The Godot native
experiment uses a separate editor/package matrix and had six v6 Linux browser matches and two relay rooms in
the rehearsal. Those receipts establish the selected package and game boundary. The source portable binary,
i686/s390x/wasip1 digest runs and Rust generic Hash behavior are not claimed as Godot ports. Fixture log
SHA-256 1e68604b6a27f11581e5d444eacfc4cebb82d5e893438694920b6a97b1c8b4ab, corpus log SHA-256
b24e8aca88753598e7cf4d40c5824e162aad6f5d92ec454124b54fb17da569d1, and native package-audit SHA-256
211aad928fc6bfe9ecd7bcccbefb88c9eb6855e7f0ec2cb5494f5635c79a8a6f. Archive member SHA-256 reviewed
f14cdf31770102e2716ff40344b33bd988b32e678a14d9b02d3d2df27adce157, candidate
37fda3a9dcc04f36006d84b4379b1142195cd7bcbc1abe6ebe6c4ad777095e14.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/specs/determinism-model.md
Independent related simulation evidence: The upstream edit describes Rust fixed-width wire/hash semantics,
native-memory-slice hashing limits, recorded checksum coverage, and upstream CI target lanes. Godot owns
canonical byte encoding and checksum callbacks in docs/integration.md and documents a separate native Linux
and exported Web matrix in docs/supported.md. The candidate matches the source schedule and trace digests on
this Linux/aarch64 host. These runs do not establish Windows, macOS, i686, s390x or WASI execution. Candidate
source tests: archive-sim-generated_schedule_digest_is_pinned.log (1 passed, SHA-256
541d8a726e6a997370f316b78497f63ac900fb112d7b68e8cb3a1d21e8a5b1cc);
archive-sim-smoke_traces_match_checked_in_cross_architecture_digests.log (1 passed, SHA-256
0cb7fa512f84f2ee90930e62eaaeea50f9156a8bb2fd3bac161f7011749b3ec5);
archive-sim-same_schedule_produces_identical_trace.log (2 passed, SHA-256
72d46712aa64382c4b3f68bd6f6720a5102dffd6771ac120f666b4afeb5c9ccd). Both candidate launch receipts passed,
SHA-256 4.3 3b90016fda5e0d644ba186470dc1f72f85b043069c8bdafa01f60906c85719e0, 4.7.2
ee84241df4f49537c08e7ef5fc0e4da3b59c47977f122f997a7d113239e5e513.

### Decision 108

`docs/specs/formal-spec.md` · `intentional_divergence`

The diff documents source SAFE-7a/b/c token and latch rules, same-cut provisional Ready digest authorization,
terminal-attempt epoch kernels, fixed fallback and split-view models, and proof-strength limits for Z3/Kani.
Godot is explicitly scoped in docs/verification-policy.md, docs/peer-lifecycle.md and docs/oracle-p2p.md. It
protects exposed checksums through its certified cut, discards departed reports, uses its locally derived
roster/era and bounded closed-operation journal, and keeps exactly one designated coordinator with an
all-survivor certificate. On both engines a delayed surviving report for frame 60 was checked after
coordinated cut 65. The v6 fallback relay source committed while the Godot participants timed out with
preserved input history. The checked-in model projection does not transfer Rust Kani/SMT proof strength or
claim fallback consensus parity. The candidate archive passed 67 P2P scenarios and the source-selected formal
handshake and spectator checks on both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929
Source-revision verification workflow
https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046813733. Reviewed archive member
SHA-256 6fb6d84115271d5b5da9203b577d0bfaa5c1c1e38c5c11f39ad3aa080190f64b and candidate
e3120652e7516d00f0f080e5a1b209e5f056164c1f35a4a8c58cb91b2ba08d5c.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/specs/formal-spec.md

### Decision 109

`docs/specs/spec-divergences.md` · `intentional_divergence`

The source adds a generated verification-manifest alignment table, classifies mathematical Z3 checks, records
narrow runtime handshake refinement, and names the source spectator models. The Godot project defines proof
bounds, non-vacuity and full trace consumption in docs/verification-policy.md. Its source-selected Godot
handshake/spectator checks bind the model inputs to candidate archive bytes, including the actual positive and
rejection witnesses. Its GDScript barrier and spectator transport deliberately have independent contracts and
no Rust Kani/SMT/Loom parity assertion. The candidate archive passed 67 P2P scenarios and the source-selected
formal handshake and spectator checks on both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929
Source-revision verification workflow
https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046813733. Reviewed archive member
SHA-256 c1275e80c3e20e88ca7299a1a5c875cd81fa6d533ef29564214c282dbe47408e and candidate
38138d3b94a7ae932115ffc2401af8aaacfac52be4ec42c2dbe73317001aa4d0.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/specs/spec-divergences.md

### Decision 110

`docs/specs/verification-manifest.toml` · `inapplicable`

Maps Rust symbols to source-project Kani, Z3, TLA and Rust checks for the upstream model-impact gate. Local
formal observers select specific trace/model files by path. See scripts/oracle/handshake_formal.py and
scripts/oracle/spectator_model.py. Compared archive member SHA-256 values are absent at the reviewed revision
and 7036630260ef26bf25a7ce4b8ebd74f22378c63ed6ed135f7a601638b37220f5 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/specs/verification-manifest.toml

### Decision 111

`docs/telemetry.md` · `inapplicable`

These hunks document the upstream SocketMetrics field and the opt-in socket trait method. Godot owns direct
and relay routing at the native boundary, including the distinct receive_native_result pressure codes in
docs/native-backend-migration.md. This checkout does not expose the source SocketMetrics API to games. Native
source provenance is verified by experiments/gdextension/verify_source.py. Archive member SHA-256 reviewed
634eed98d45472aea8a07dceadcb80c15552c0996e6ff259ac1f77fd5ce33fb3, candidate
54900d54b1ec9c62286fa1d988514f96b4e1ed19bae213ce498b923827437919.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/telemetry.md

### Decision 112

`docs/threat-model.md` · `intentional_divergence`

The changed threat-model passages add source UDP adapter counters and explicitly distinguish adapter
acceptance from protocol enqueue demand. The actual Godot native Socket implementation in
experiments/gdextension/src/peer.rs implements the send and receive methods and uses the trait’s zero-metrics
default; the driver reports bounded Accepted/Rejected/Full results. The GDScript adapter requires an
attributed sender and bounded packet work, reports ACCEPTED, BACKPRESSURE or failure, and defines ACCEPTED as
local ownership. See docs/contracts.md#transport-boundary and docs/signalfish-relay.md. This classifies the
different telemetry and ownership contract. It does not generalize a socket or packet cap to attack
resistance. Archive member SHA-256 reviewed 7ef9f26e3ba0ed28092c47f36bb62a761331ae348d0f6d7f0a2ba103206deaed,
candidate dae1674c0b32e4d79c9fcdfeb1d8ba95524cfe506b7740d2b7bac8f38cdccc5b.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/threat-model.md

### Decision 113

`docs/tuning.md` · `intentional_divergence`

These upstream measurements describe the Rust stage and configuration, including 16-peer timing budgets, named
P2P pacing cells, transport queue/counter bounds, the acknowledgement-floor penalty under the named asymmetric
and poor network workloads, and the 66-row fleet ledger. Godot's supported envelope remains 2-8 fixed players
and documented fault/delay/window cases in docs/reference/p2p-profiles.md. Godot benchmarks use their own
engine/host/workload, reproducible checksums and measured budget policy in
docs/experiments/session-hot-path-performance.md and docs/verification-policy.md. The exact source PR sweep
and five pacing cases were green in targeted source runs. These timings, fault-fleet coverage and throughput
thresholds are specific to their source lanes and are not imported as Godot support. Run log SHA-256
a8052ddb86d3d95c9cc8d04d63afa13ea2a9b363fe561d7014f6fe233961d782 and
1046d548ed66eacd66f33e30423243f28d58584f6d23d37976ce97666833a32b. The candidate archive passed 67 P2P
scenarios and the source-selected formal handshake and spectator checks on both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929 Reviewed
archive member SHA-256 9402430b0ea57736da5cbcfcacde08b31d8db75635f092f6bba0f5b6f682f208 and candidate
16ac26ae220faa19dd2488a812fe98f39a109d1ef33375f656230bcee49d4c5d.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/tuning.md

### Decision 114

`docs/user-guide.md` · `intentional_divergence`

This is the Rust application guide for recovery-only service, fallible macros and typed Rust errors, Tokio and
the exercise census, coordinated removal with epoch/authority/fallback behavior and spectator truncation. The
deployed Godot interfaces in docs/session.md, docs/peer-lifecycle.md and docs/spectators.md own analogous
recovery, safe ordered callback completion and fail-closed outcomes. They use a single configured source for
playback, a fixed roster, negotiated byte protocol, and a separately validated state checksum domain. The
reference candidate completed 257 decoded final rows for both peers, and its positive and withheld cases
preserve the observed 257 and 256/255 boundaries. The extension package retains its separately qualified
fixed-membership scope. The candidate archive passed 67 P2P scenarios and the source-selected formal handshake
and spectator checks on both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929 Candidate
package qualification has 12 digest-verified platform/editor results, 32 canonical 40-row matches and 32
restore/encoding controls.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492 Reviewed archive
member SHA-256 e54626933323ff011763b530c9e03d94dbc1363b10bdfa38040867e4c846e10f and candidate
b69ebd978e17a565a9117d61c14f28061a573c68b7fde790c599b41d8ee5ae54.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/docs/user-guide.md

### Decision 115

`examples/request_handling.rs` · `ported`

The upstream example aborts request processing when saved state is unavailable or a required checksum cannot
be produced. Godot uses typed callback completion instead of a Rust macro. tests/unit/test_driver.gd covers
failed callbacks and unavailable rollback history; tests/unit/test_snapshot_history.gd rejects failed saves
and absent or malformed checksums. docs/native-backend-migration.md defines the same first-failure stop for
the native driver. Archive member SHA-256 reviewed
d2411bb15c22aef5a701a4b9a040a19bc8f4d72df3e729f0cd8b6a66ef72a252, candidate
0abf7894d6590eae1050114d5537c19cfd506b4f11ccc7f14e4b14247ef8f502.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/examples/request_handling.rs

### Decision 116

`examples/sync_test.rs` · `ported`

The upstream example aborts request processing when saved state is unavailable or a required checksum cannot
be produced. Godot uses typed callback completion instead of a Rust macro. tests/unit/test_driver.gd covers
failed callbacks and unavailable rollback history; tests/unit/test_snapshot_history.gd rejects failed saves
and absent or malformed checksums. docs/native-backend-migration.md defines the same first-failure stop for
the native driver. Archive member SHA-256 reviewed
3327e6870d92b8f0e805a0d307a19a63cbf7c7aab5f73b0f1b551594a06b5999, candidate
b979f732391b4e088a7a4581b14d481e23527a68400898cafc46ebfb9a096ec4.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/examples/sync_test.rs

### Decision 117

`fuzz/Cargo.lock` · `inapplicable`

Resolves the standalone fortress-rollback-fuzz package under fuzz/Cargo.toml. The selected reference runner
selects tests from the main crate using its root lockfile. See scripts/reference/run.py and
docs/reference/pins.json. Compared archive member SHA-256 values are
2e1c209750e6f6523f8ca86a1e51234dee8d854f5004ad7054f1c9a0baf2e6e4 at the reviewed revision and
6d0a8e2d2e94774421c619db4a2c31e3809e02fadac505f38ae79e59a88f288b at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/fuzz/Cargo.lock

### Decision 118

`loom-tests/Cargo.lock` · `inapplicable`

Resolves the standalone fortress-rollback-loom-tests package configured with cfg(loom). The selected reference
runs use the main crate and no Loom configuration. See scripts/reference/run.py. Compared archive member
SHA-256 values are b8059f822f4cf4c1f92a71321c771e1e6b4eab9d8c39e85b271e2373c58adf4c at the reviewed revision
and 901e3a5b05c58c1ea8f8f6af048363ed14957d0593958b3aebb38a2726d9cb98 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/loom-tests/Cargo.lock

### Decision 119

`mkdocs.yml` · `inapplicable`

Configures the source repository’s MkDocs site. The Godot reference consumes verified archives and explicitly
invokes its own oracle entry points. See docs/reference/README.md. Compared archive member SHA-256 values are
e6511f127b70acd830a82e03c1d07a6f1ea471dcbc7b621dca21f78c28715fa5 at the reviewed revision and
9f1ea95019891c931873e677de2a74e0182574c506b3530b4a01835822e30c99 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/mkdocs.yml

### Decision 120

`mypy.ini` · `inapplicable`

Configures type checks for upstream Python sources. The Godot gate invokes its own harness lint and tests. See
.github/workflows/gate.yml. Compared archive member SHA-256 values are
d9fb4612290ac124e39ad75b4240deb55fa630ea8e4ddfa82e806dfb9023dba2 at the reviewed revision and
a3a27110e366910fe037f4dc60e8d2f8b7485c6601a41550330289abf00f751e at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/mypy.ini

### Decision 121

`opencode.json` · `inapplicable`

Upstream development container or editor/agent setup. The local container is built from this checkout’s
.devcontainer/Dockerfile and installs its own tools through .github/workflows/devcontainer.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
a4873c300b1398b82c7907c21f5846b2b01e90d896fa0c7fd91ed31eff3c4b35 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/opencode.json

### Decision 122

`progress/session-177-z3-021-verification-refresh.md` · `inapplicable`

This file records the removed source-project Z3 verification session log. The Godot repository owns those
processes through .llm/context.md and .github/workflows/gate.yml. Compared archive member SHA-256 values are
51bcb335e2d23e44fb9e2266702869710afc426a92c1e0b4a48652db438751fe at the reviewed revision and absent at the
candidate.
https://github.com/wallstop/fortress-rollback/blob/d124c89080004d96971a629bb0427056ee1805e3/progress/session-177-z3-021-verification-refresh.md

### Decision 123

`proptest-regressions/network/codec.txt` · `intentional_divergence`

The new seed is an upstream Rust codec regression artifact. It stays in the exact archive, where the source
library test suite ran. The port uses a distinct fixed-width packet codec and retains its own parser controls.
No raw cross-wire interpretation is implied. Candidate all-library 2,103-test output SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Archive member SHA-256 before absent, after
ec234cbf06d8d97daf1346f80be2fc0ebed6f1d0624cfc548e3cf4889be2c8d0.

### Decision 124

`requirements-docs.txt` · `inapplicable`

Installs dependencies for the upstream documentation build. The Godot reference runners invoke the local
Python tools and pinned compiler or engine. See docs/reference/README.md. Compared archive member SHA-256
values are dca1150f974b42f0e9176729f5d4496009f6b7daad74e574ac5119a853a14633 at the reviewed revision and
770dc4a0ba6ba146e6e36b7a26525ba367f6ebf26f03ad2195aed30592f2bfd5 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/requirements-docs.txt

### Decision 125

`ruff.toml` · `inapplicable`

Configures linting for the source repository’s Python tooling. The Godot gate invokes its own source and
harness lints. See .github/workflows/gate.yml. Compared archive member SHA-256 values are
6089b7eb214b3952b79b7cfd4bcb111e12ab0485ebe72be4e3c93fd8ef6d0ee6 at the reviewed revision and
9b61f891628ab646d14854d93e807de8a182e7f8d0ba32523d6f74d21ac0ccd0 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/ruff.toml

### Decision 126

`rust-toolchain.toml` · `inapplicable`

Selects stable, Clippy and rustfmt for contributors working at the upstream root. The selected Rust reference
explicitly invokes cargo +1.99.1 via the checked-in tool manifest. See scripts/reference/run.py and
docs/reference/pins.json. Compared archive member SHA-256 values are absent at the reviewed revision and
a3231c16bc97a5923472ea8348affe9aa41973c19ab50730cd697c3340c17700 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/rust-toolchain.toml

### Decision 127

`scripts/ci/agent-preflight.py` · `inapplicable`

This tool runs the source project’s preflight checks. The selected Godot gates call the checkout’s own tools
through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Compared archive member
SHA-256 values are b4d08729b57480e0a2802643ce2462d4dfa0d8e5f7ec77350926ecce0406fadb at the reviewed revision
and 032abf72f2b57bd04929eb794b133c7bdc08b7cda14d2f23140e8517f71f3ae1 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/ci/agent-preflight.py

### Decision 128

`scripts/ci/check-doc-claims.sh` · `inapplicable`

This tool checks Rust documentation claim markers in the source repository. The selected Godot gates call the
checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Compared
archive member SHA-256 values are 50a46c4d5ecac5c49a0d23edac93756001c1183b88f4bd8a03130a21295264f6 at the
reviewed revision and 8f1bfb03092501758de980bfd97d95c7151cd8e9901e57ee73aedd569e1c8dc2 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/ci/check-doc-claims.sh

### Decision 129

`scripts/ci/check-mesh-advance-budget.py` · `inapplicable`

This checker reads Criterion JSON from the source-only warmed 8/16-peer Rust benchmark and compares its
medians to absolute source-runner budgets. The Godot project neither consumes those Criterion JSON files nor
sets those full-mesh thresholds. See the separate benchmark in experiments/gdextension/benchmark.py and its
documented workload in docs/experiments/upstream-binding.md. Compared archive member SHA-256 values are absent
and 69c1208a9c1e76434fb67f6c4f47ebcc6812f8169d6a2eab5a9b03ed52abde24.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/ci/check-mesh-advance-budget.py

### Decision 130

`scripts/ci/check-tools.sh` · `inapplicable`

This tool checks tools installed in the source project’s development container. The selected Godot gates call
the checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml.
Compared archive member SHA-256 values are 8da308a9c330058a68fe4aa28063fdbcb2c9ecdd8becd9c77c33eace9544681a at
the reviewed revision and f161af4ea54a67eb81df119f77236d254e791fb760dd5637079c581a143105ea at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/ci/check-tools.sh

### Decision 131

`scripts/ci/ci_metrics.py` · `inapplicable`

This tool summarizes runs from the source project’s GitHub Actions workflows. The selected Godot gates call
the checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml.
Compared archive member SHA-256 values are absent at the reviewed revision and
343b2e11a8cf44b1281f962539460324479fa77705812c7496715716d7a77d1a at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/ci/ci_metrics.py

### Decision 132

`scripts/ci/detect-kani-changes.sh` · `inapplicable`

This tool routes Kani code generation checks from the source project’s changed paths. The selected Godot gates
call the checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml.
Compared archive member SHA-256 values are absent at the reviewed revision and
267ba52f404f866999957b57502a00493f4876f6d2f19fb5086db2c960088aca at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/ci/detect-kani-changes.sh

### Decision 133

`scripts/ci/session-budget.py` · `inapplicable`

This tool manages the source project’s coding-agent session budgets. The selected Godot gates call the
checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
53e3bc58ae8e6a4ab772adf00e6298e178857cdbf099477bad4df807cdd1429c at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/ci/session-budget.py

### Decision 134

`scripts/ci/vscode-github-token.py` · `inapplicable`

This tool configures the source development container’s editor credentials. The selected Godot gates call the
checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
1cb4115ec8074f25461735a9211276b1d1ef49219bfe51286b157341b96cac8b at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/ci/vscode-github-token.py

### Decision 135

`scripts/dev/clean-artifacts.sh` · `inapplicable`

This tool cleans generated build and verification artifacts in the source development workspace. The selected
Godot gates call the checkout’s own tools through .github/workflows/gate.yml and
.github/workflows/reference-baseline.yml. Compared archive member SHA-256 values are absent at the reviewed
revision and 3545696bcef9dc1a4c8806d302a3638fdca98298396351c54e7855c0f20fdee4 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/dev/clean-artifacts.sh

### Decision 136

`scripts/docs/check-agent-skills.sh` · `inapplicable`

This tool invokes the source project’s agent-skill check. The selected Godot gates call the checkout’s own
tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Compared archive member
SHA-256 values are 7d4986af01da8061b875761cd9fba7192b8e5b2322aba651d928d45776d1dc30 at the reviewed revision
and 0f165166aee5cf55097add635a674cd39d45d14015a65a8129a38374a4321071 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/docs/check-agent-skills.sh

### Decision 137

`scripts/docs/check_agent_skills.py` · `inapplicable`

This tool validates the source project’s agent-skill layout. The selected Godot gates call the checkout’s own
tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Compared archive member
SHA-256 values are absent at the reviewed revision and
9991c3bded8450f1884c60f0fc0eb37bbb7a7374a28bc1aa2697185aeb09817c at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/docs/check_agent_skills.py

### Decision 138

`scripts/docs/sync-wiki.py` · `inapplicable`

This tool renders and synchronizes the source project’s GitHub wiki. The selected Godot gates call the
checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Compared
archive member SHA-256 values are 4c64e0d871b1fb85d069ae41111fa369eaa2fbd562958c0cd4f395e80d3f2b5e at the
reviewed revision and 1e1b5382596645b262314182b3647aad6da62a4be9a96aad51d458611977801d at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/docs/sync-wiki.py

### Decision 139

`scripts/hooks/check-plan-hygiene.py` · `inapplicable`

This tool checks the source project’s plan files through its Git hooks. The selected Godot gates call the
checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Compared
archive member SHA-256 values are 2a296872493579971b34a4c68ef96692e62401f0527ec363ac643fc1ddcc2959 at the
reviewed revision and eaf03ffdee84b35a5c0b2b28a90959521bbe05ba82e085f2394b8ee00a77423d at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/hooks/check-plan-hygiene.py

### Decision 140

`scripts/hooks/check-rust-semantic-claims.py` · `inapplicable`

This tool enforces Rust semantic-claim review rules in source-project changes. The selected Godot gates call
the checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml.
Compared archive member SHA-256 values are 89e9fe5e94c95814e57e6510d2d8889d8b78f432157be7df217bee05f9ad60a8 at
the reviewed revision and 088321f39be0cacf7e0ffb202e0fc1678e63827f5beaa5cfd17ef13467ac1823 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/hooks/check-rust-semantic-claims.py

### Decision 141

`scripts/hooks/check-wire-golden-immutable.py` · `inapplicable`

This tool polices edits to released Rust wire literals in source-project changes. The selected Godot gates
call the checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml.
Compared archive member SHA-256 values are fdb34b70aa6c8202dba7d509a18fd3c26c4007c34a59b0a7b4e9389c50373e81 at
the reviewed revision and b85200afc6f9ce54734d8362542c64470609aba6d5d066f3dd117559791a0078 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/hooks/check-wire-golden-immutable.py

### Decision 142

`scripts/release/main_ruleset.py` · `inapplicable`

This tool or lock supports rule management and release tests in the upstream GitHub repository. The selected
local build installs the Rust toolchain and builds the archive dependency directly. See
scripts/reference/run.py and experiments/gdextension/Cargo.toml. Compared archive member SHA-256 values are
e33670a2ae0227023ca8124d4dbcbb15ec5f76a7f57dfdd70e1ee8fb277ed269 at the reviewed revision and
309bd87e199ac3d957cd76791deb4b1c37e1d520a8e9b04b8dca04c3f3ea2e59 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/release/main_ruleset.py

### Decision 143

`scripts/release/requirements.txt` · `inapplicable`

This tool or lock supports rule management and release tests in the upstream GitHub repository. The selected
local build installs the Rust toolchain and builds the archive dependency directly. See
scripts/reference/run.py and experiments/gdextension/Cargo.toml. Compared archive member SHA-256 values are
3be8ee3d6c328e70666a0bb3bd02df4a1fcfd9a6bd062b16859b956f84938e63 at the reviewed revision and
68c6dc4320d45926309b9c843f9093a2210292f64d1077a364eece2abf08bf76 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/release/requirements.txt

### Decision 144

`scripts/simulation/violation-site-baseline.tsv` · `inapplicable`

This tool lists the source project’s Rust violation-report sites for its census. The selected Godot gates call
the checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml.
Compared archive member SHA-256 values are absent at the reviewed revision and
bba199ab1f0aaae7d242a6115bb94747a138c4b7acd38d416110967b56a05d49 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/simulation/violation-site-baseline.tsv

### Decision 145

`scripts/simulation/violation_census.py` · `inapplicable`

This tool joins LLVM and source Rust fleet outputs with violation-site inventory. The selected Godot gates
call the checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml.
Compared archive member SHA-256 values are absent at the reviewed revision and
062e578b5eb349cc8452e8d5a2538fb8565eff527b2081b52f5579a40fe8f436 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/simulation/violation_census.py

### Decision 146

`scripts/simulation/violation_sites.py` · `inapplicable`

This tool inventories the source tree’s Rust violation-report macros. The selected Godot gates call the
checkout’s own tools through .github/workflows/gate.yml and .github/workflows/reference-baseline.yml. Compared
archive member SHA-256 values are absent at the reviewed revision and
1f5f06ee08abf0334c7c11fa42fe2185cfff8b9f8a10309f4b12cd828f56f8c0 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/simulation/violation_sites.py

### Decision 147

`scripts/tests/test-ai-backends.sh` · `inapplicable`

Exercises upstream selection of source container AI backends. The Godot gate runs the checkout’s own Python
self-tests and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
absent at the reviewed revision and cb8bba132ad5cdea8ac48c674a913c58e5133a33c0cdbc4c1558d0ce3fa065ea at the
candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test-ai-backends.sh

### Decision 148

`scripts/tests/test_agent_preflight.py` · `inapplicable`

Exercises upstream agent preflight. The Godot gate runs the checkout’s own Python self-tests and oracle
controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
10c77fe1b80609c9c2edce3551d3fb2223f78173141cf4ef56d2d0910419f2e1 at the reviewed revision and
fd417065ee9416adbd0a15ffeb4bf9bf79d8107a8d9ca6d1ed4f9badd4f5b932 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_agent_preflight.py

### Decision 149

`scripts/tests/test_check_benchmark_regressions.py` · `inapplicable`

Exercises upstream benchmark-regression tooling. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
fb5b6b71e34be1cf326b817bd76f03030565d2de2c87ba20e6bfe0b94b64056b at the reviewed revision and
c3bc4d863f1ce6da3f3298819bc5d93bbfc73692b8d5b7bc0ef35b6135bc08dd at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_check_benchmark_regressions.py

### Decision 150

`scripts/tests/test_check_mesh_advance_budget.py` · `inapplicable`

Exercises upstream Criterion mesh-performance budget tooling. The Godot gate runs the checkout’s own Python
self-tests and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
absent at the reviewed revision and b84d47e8c89ff9ec24762b3d85003f67e83fe9f911c4299288cc6297087852d1 at the
candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_check_mesh_advance_budget.py

### Decision 151

`scripts/tests/test_check_wire_golden_immutable.py` · `inapplicable`

Exercises upstream the wire-golden immutability hook. The Godot gate runs the checkout’s own Python self-tests
and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
396cdb439aa8164f36241dec7dfae9f99cb440146d2265a9e55b58881472f548 at the reviewed revision and
75c81290a137953765bb61f4ecc24b44d1581c8f9fdd0e29a1b54770271772e2 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_check_wire_golden_immutable.py

### Decision 152

`scripts/tests/test_ci_deduplication.py` · `inapplicable`

Exercises upstream workflow scheduling and deduplication. The Godot gate runs the checkout’s own Python
self-tests and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
absent at the reviewed revision and 3c3d723722946fc9547fd648445f654bf9d8290eef0f09bb0f1488ad959022cd at the
candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_ci_deduplication.py

### Decision 153

`scripts/tests/test_ci_fuzz_nightly_workflow.py` · `inapplicable`

Exercises upstream the fuzz nightly workflow. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are absent at the
reviewed revision and 9b82f6964f3b33fe91c76429542d46fae9f1be9fa5902089861b2272cb832ca9 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_ci_fuzz_nightly_workflow.py

### Decision 154

`scripts/tests/test_ci_metrics.py` · `inapplicable`

Exercises upstream CI metrics tooling. The Godot gate runs the checkout’s own Python self-tests and oracle
controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are absent at the reviewed
revision and 0fc05da228de1616c75077076b78fdcea4fc7f6a2471c761e51495b2316a6a7a at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_ci_metrics.py

### Decision 155

`scripts/tests/test_ci_mutation_workflow.py` · `inapplicable`

Exercises upstream the Cargo mutation workflow. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
9bf04b7ce0386f451a42b99e005927492d333f505d585225b7c55674b3e9cd02 at the reviewed revision and
58fd821c60bf3f9d0eaf4657dda409807f48d85a076e07e576013563074b5f71 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_ci_mutation_workflow.py

### Decision 156

`scripts/tests/test_ci_pr_gate_workflow.py` · `inapplicable`

Exercises upstream the pull-request gate workflow. The Godot gate runs the checkout’s own Python self-tests
and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are absent at
the reviewed revision and 22d44642871f041959171e7360033721fceb621af8ad57ea87653b84dff9e5b0 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_ci_pr_gate_workflow.py

### Decision 157

`scripts/tests/test_ci_rust_workflow.py` · `inapplicable`

Exercises upstream the Rust workflow. The Godot gate runs the checkout’s own Python self-tests and oracle
controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
5d11c6c0dfc32d54dd32be6c7ed89ea5cf151c1faef8e06eb2bcaaf43f3fd6ec at the reviewed revision and
18596b474ac793d3a16ec743eebd49caccd76857a236e46abd2e0af5b7b4d599 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_ci_rust_workflow.py

### Decision 158

`scripts/tests/test_ci_simulation_nightly_workflow.py` · `inapplicable`

Exercises upstream the simulation nightly workflow. The Godot gate runs the checkout’s own Python self-tests
and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
faf88f5c2820d3b15e2f10e19cb664d8380262053cc8badbb8415e7bfc82e685 at the reviewed revision and
fa0b1b292896e292a7a7fb1b2e6cc3942e26e39be34f21ba21649a1e8935cb26 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_ci_simulation_nightly_workflow.py

### Decision 159

`scripts/tests/test_ci_static_analysis.py` · `inapplicable`

Exercises upstream static-analysis tooling. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
8ccd4cd3c03cb826f6e264ac4ab0bb2af55a5acb1a40028426346d0d01ac3b2f at the reviewed revision and
c025f00ea4b42d4bbe832a6818b57e3ea0d72e529f3fecbeb2f4e40af66c93df at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_ci_static_analysis.py

### Decision 160

`scripts/tests/test_ci_toolchains.py` · `inapplicable`

Exercises upstream source CI toolchain setup. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
fff3c7dcc0e63a0d231ef1a7fb45d85466ec637635bf972abd0c1f19f3b9d8aa at the reviewed revision and
db64e32b8b898a94d6fb5d3b0ee6f6c6eac211624bea3e5c549b8bf4a6943cce at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_ci_toolchains.py

### Decision 161

`scripts/tests/test_codex_devcontainer_setup.py` · `inapplicable`

Exercises upstream the source container’s Codex setup. The Godot gate runs the checkout’s own Python
self-tests and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
c978e24cb2eed1a936e6258a297148f2c26e362e06065953905820dc7535666b at the reviewed revision and
27a744480cb82e5fc5ecdfe772d13733e0adadcc7ecc42e500e1bbcce05030de at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_codex_devcontainer_setup.py

### Decision 162

`scripts/tests/test_git_hook_policy.py` · `inapplicable`

Exercises upstream source Git hooks. The Godot gate runs the checkout’s own Python self-tests and oracle
controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
b1fafe00967be06b8aaafbb6e3c83c9b4bfdaa809dce7b4e10f3a494033342af at the reviewed revision and
d8a9abd10060fa25f8d28f5325774f682f28e4a12f1df62e09749355e6bd4b51 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_git_hook_policy.py

### Decision 163

`scripts/tests/test_main_ruleset.py` · `inapplicable`

Exercises upstream the main-branch ruleset. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
16ad82e54ebe6c77998f2647c705df39bca1b744567414889d2607011da3a7bf at the reviewed revision and
7d7cbb3a33cb35d40e7f261a95b778a3bc76db7f8df09f40f5324aff48a7e781 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_main_ruleset.py

### Decision 164

`scripts/tests/test_merge_queue_ruleset.py` · `inapplicable`

Exercises upstream the merge-queue ruleset. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are absent at the
reviewed revision and 0b7d17e7ba46da9e07c20c668b58449d3c5c0370f10841b3c55840230a0b35c6 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_merge_queue_ruleset.py

### Decision 165

`scripts/tests/test_model_impact.py` · `inapplicable`

Exercises upstream the code-to-proof manifest checker. The Godot gate runs the checkout’s own Python
self-tests and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
absent at the reviewed revision and 463287c4b67574baee499fa2082d887d8d7ad371de1b0ff78502d6ff6fff86c5 at the
candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_model_impact.py

### Decision 166

`scripts/tests/test_plan_hygiene.py` · `inapplicable`

Exercises upstream the source plan checks. The Godot gate runs the checkout’s own Python self-tests and oracle
controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
0548787f93c97fa1be7989727eb90458a8d473f78692d22e37e8685ffd310bbb at the reviewed revision and
e40af9095fe27c8bb93cfe043d0e7a9d364f34171222e6bc8c1d9fddfb3d17ac at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_plan_hygiene.py

### Decision 167

`scripts/tests/test_release_workflows.py` · `inapplicable`

Exercises upstream the source release workflows. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
9e2dadd943aa98d9a637713ccaa0bf3447544ffc490f147c8bdc5ddbe59d0b0d at the reviewed revision and
69b41c8c9346db6dfdbe6b98712a624de37e8a335b155c3a0975b862b649f437 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_release_workflows.py

### Decision 168

`scripts/tests/test_rust_semantic_claims_scope.py` · `inapplicable`

Exercises upstream scope checks in the Rust semantic-claim hook. The Godot gate runs the checkout’s own Python
self-tests and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
absent at the reviewed revision and 3243ce5bb118351fabb276bf448fd46827c9b044aad54d97ecdfb1d383a9e11c at the
candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_rust_semantic_claims_scope.py

### Decision 169

`scripts/tests/test_session_budget.py` · `inapplicable`

Exercises upstream coding-agent session budgets. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are absent at the
reviewed revision and 34f82fb9ffb4c4deb4be55847ba20ac9c655233c09900183dbc73bf66dc8b804 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_session_budget.py

### Decision 170

`scripts/tests/test_validate_agent_skills.py` · `inapplicable`

Exercises upstream source agent-skill validation. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
d195ff9c1e12fa65b0142ceb5c347ec3c8f055ab2f83a81275dede6704acaa41 at the reviewed revision and
67511850ec965b12d5b4b7e1a091a6a42e4eb5d5947944662f01796f863a3e78 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_validate_agent_skills.py

### Decision 171

`scripts/tests/test_verify_all.py` · `inapplicable`

Exercises upstream the source verifier’s orchestration. The Godot gate runs the checkout’s own Python
self-tests and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
absent at the reviewed revision and ee53f504cacf5e8d7ee7bb84288ecede8a3d81e8d682ea2f3002d0ec65e080d3 at the
candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_verify_all.py

### Decision 172

`scripts/tests/test_violation_census.py` · `inapplicable`

Exercises upstream the violation census tool. The Godot gate runs the checkout’s own Python self-tests and
oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are absent at the
reviewed revision and af53c9543183e973299f7747372c82b68744972638e6a673d7b5af71315cb4f3 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_violation_census.py

### Decision 173

`scripts/tests/test_violation_sites.py` · `inapplicable`

Exercises upstream Rust violation-site inventory tooling. The Godot gate runs the checkout’s own Python
self-tests and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
absent at the reviewed revision and 2146b32d04573fb2fb5759b03d6408abda5589ed38b0fc03f5c8eadf327ba50c at the
candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_violation_sites.py

### Decision 174

`scripts/tests/test_vscode_github_token.py` · `inapplicable`

Exercises upstream the source container’s editor credential helper. The Godot gate runs the checkout’s own
Python self-tests and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256
values are absent at the reviewed revision and
a1faa1aa022a891e07b5ab36020cd3d119ff804c5b514260a8beb79a0f226fca at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_vscode_github_token.py

### Decision 175

`scripts/tests/test_workspace_locks.py` · `inapplicable`

Exercises upstream the source project’s workspace locks. The Godot gate runs the checkout’s own Python
self-tests and oracle controls through .github/workflows/gate.yml. Compared archive member SHA-256 values are
2fcd3f5b0dd1b8a0aac842a1374497d2caf2dda68551bd209e6d56e4e70385f0 at the reviewed revision and
58c2a80372aa23e88c9f900969bb688167cd565920d23c01e1c34dbae730f93c at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/tests/test_workspace_locks.py

### Decision 176

`scripts/verification/lean-varint-pilot/.gitignore` · `inapplicable`

Artifact of the opt-in Lean pilot on the upstream Rust varint module. The candidate pilot README records that
it is outside upstream CI and its smoke crate includes the Rust file directly. The selected Godot gates build
the crate and compare their own protocol observations. See scripts/oracle/parallel_launchers.py. Compared
archive member SHA-256 values are absent at the reviewed revision and
c3949e59b5371e026885e8baf97bf45c9e7c388c859f3b2ba1eed2c6d03320da at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/lean-varint-pilot/.gitignore

### Decision 177

`scripts/verification/lean-varint-pilot/Audit.lean` · `inapplicable`

Artifact of the opt-in Lean pilot on the upstream Rust varint module. The candidate pilot README records that
it is outside upstream CI and its smoke crate includes the Rust file directly. The selected Godot gates build
the crate and compare their own protocol observations. See scripts/oracle/parallel_launchers.py. Compared
archive member SHA-256 values are absent at the reviewed revision and
32bce9227a786046b4506a403e48b0c620f83640e0e1912c844078ce06554f44 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/lean-varint-pilot/Audit.lean

### Decision 178

`scripts/verification/lean-varint-pilot/Contracts.lean` · `inapplicable`

Artifact of the opt-in Lean pilot on the upstream Rust varint module. The candidate pilot README records that
it is outside upstream CI and its smoke crate includes the Rust file directly. The selected Godot gates build
the crate and compare their own protocol observations. See scripts/oracle/parallel_launchers.py. Compared
archive member SHA-256 values are absent at the reviewed revision and
0067bf5f406e66bf8d58bcac288c9204dcbd8fc2704cb68e9e50f1fc0ff7b5c4 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/lean-varint-pilot/Contracts.lean

### Decision 179

`scripts/verification/lean-varint-pilot/MANIFEST.sha256` · `inapplicable`

Artifact of the opt-in Lean pilot on the upstream Rust varint module. The candidate pilot README records that
it is outside upstream CI and its smoke crate includes the Rust file directly. The selected Godot gates build
the crate and compare their own protocol observations. See scripts/oracle/parallel_launchers.py. Compared
archive member SHA-256 values are absent at the reviewed revision and
51ba3ba585b86609fe2db759ed7806740454eb57fa44c79e54397bdedc7f6551 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/lean-varint-pilot/MANIFEST.sha256

### Decision 180

`scripts/verification/lean-varint-pilot/README.md` · `inapplicable`

Artifact of the opt-in Lean pilot on the upstream Rust varint module. The candidate pilot README records that
it is outside upstream CI and its smoke crate includes the Rust file directly. The selected Godot gates build
the crate and compare their own protocol observations. See scripts/oracle/parallel_launchers.py. Compared
archive member SHA-256 values are absent at the reviewed revision and
b7fcc1a4a0886b7d68ceb8d5ce70d089b871a20d0f81aab55ff068535f2a417e at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/lean-varint-pilot/README.md

### Decision 181

`scripts/verification/lean-varint-pilot/run.sh` · `inapplicable`

Artifact of the opt-in Lean pilot on the upstream Rust varint module. The candidate pilot README records that
it is outside upstream CI and its smoke crate includes the Rust file directly. The selected Godot gates build
the crate and compare their own protocol observations. See scripts/oracle/parallel_launchers.py. Compared
archive member SHA-256 values are absent at the reviewed revision and
927ea3e030811adc2f145d80e651b4b16c8dc2c178deb9532b3369533578f32d at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/lean-varint-pilot/run.sh

### Decision 182

`scripts/verification/lean-varint-pilot/smoke/Cargo.lock` · `inapplicable`

Artifact of the opt-in Lean pilot on the upstream Rust varint module. The candidate pilot README records that
it is outside upstream CI and its smoke crate includes the Rust file directly. The selected Godot gates build
the crate and compare their own protocol observations. See scripts/oracle/parallel_launchers.py. Compared
archive member SHA-256 values are absent at the reviewed revision and
9b68c594efb9abb3ddbd2fafe9ab1861bc3c88cda7c946dbf7fc47d33ed367d7 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/lean-varint-pilot/smoke/Cargo.lock

### Decision 183

`scripts/verification/lean-varint-pilot/smoke/Cargo.toml` · `inapplicable`

Artifact of the opt-in Lean pilot on the upstream Rust varint module. The candidate pilot README records that
it is outside upstream CI and its smoke crate includes the Rust file directly. The selected Godot gates build
the crate and compare their own protocol observations. See scripts/oracle/parallel_launchers.py. Compared
archive member SHA-256 values are absent at the reviewed revision and
8e6a5ad726d397b34033b45c2308b68d4d5ca11acf9b2cb5a7058f794d4c5a26 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/lean-varint-pilot/smoke/Cargo.toml

### Decision 184

`scripts/verification/lean-varint-pilot/smoke/src/lib.rs` · `inapplicable`

Artifact of the opt-in Lean pilot on the upstream Rust varint module. The candidate pilot README records that
it is outside upstream CI and its smoke crate includes the Rust file directly. The selected Godot gates build
the crate and compare their own protocol observations. See scripts/oracle/parallel_launchers.py. Compared
archive member SHA-256 values are absent at the reviewed revision and
ed83d98f2c76842c6ade5560c4e8354e1be85959672c3c0234f017345d85f391 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/lean-varint-pilot/smoke/src/lib.rs

### Decision 185

`scripts/verification/model-impact.py` · `inapplicable`

This script checks changes against the upstream code-to-proof manifest. Godot’s nightly launcher invokes its
own scoped source-backed models through scripts/oracle/handshake_formal.py and
scripts/oracle/spectator_model.py. Compared archive member SHA-256 values are absent at the reviewed revision
and f4849c2a0a1e4cd5e184a3733af57c977039509e29f676589a3feb44bdfcb1f7 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/model-impact.py

### Decision 186

`scripts/verification/verify-all.sh` · `inapplicable`

This script orchestrates the source repository’s verification suites. Godot’s nightly launcher invokes its own
scoped source-backed models through scripts/oracle/handshake_formal.py and scripts/oracle/spectator_model.py.
Compared archive member SHA-256 values are 282e78aeed94f1e19193628535218f167005e0af016b66c24bf5c2c25dc209aa at
the reviewed revision and 596644d5f4b16fbee6a77a086698523e26f8e9a59fa89048465f0e9b7b9ba946 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/verify-all.sh

### Decision 187

`scripts/verification/verify-kani.sh` · `inapplicable`

This script orchestrates upstream Kani proof runs. Godot’s nightly launcher invokes its own scoped
source-backed models through scripts/oracle/handshake_formal.py and scripts/oracle/spectator_model.py.
Compared archive member SHA-256 values are 906ceaae346bc2ccef84dabc92886c20e04d318d2861b34baa2d870a4b99b227 at
the reviewed revision and 39afb1d8af8ddfd924e86dc28193ef85ca62bed325ae340d6ef3fe7d33957acc at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/verify-kani.sh

### Decision 188

`scripts/verification/verify-tla.sh` · `inapplicable`

This script orchestrates upstream TLC sweeps. Godot’s nightly launcher invokes its own scoped source-backed
models through scripts/oracle/handshake_formal.py and scripts/oracle/spectator_model.py. Compared archive
member SHA-256 values are a71a7432e7e9b38f1473d4b67e43f918619bea8fe96034febba56ad46602f31c at the reviewed
revision and e8e07e56f9b925a4125fc68c32cad20021584e3d2990f1b496d8dbfdb0176d8f at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/scripts/verification/verify-tla.sh

### Decision 189

`specs/tla/ChecksumBasis.cfg` · `intentional_divergence`

Exact upstream TLC 1.8.0 checked all four bounded invariants in 57,493 distinct states. The two alternate
configurations reached the expected WitnessGoal and NoPermanentFalseNegative violations. This model checks
source-specific per-slot basis token behavior. Godot has a distinct byte contract and protects exposed
confirmed history via Session.confirmed_checksums and confirmed_freeze_floor, which the coordinator
incorporates into its cut and each follower rechecks. The actual delayed survivor report on Godot 4.3 and
4.7.2 crossed cut 65, compared the saved frame 60 checksum after recovery (verified_reports 0 to 1), and
preserved the confirmed frontier and canonical current state. This scoped comparison exercises protected
retained history. It does not claim general protocol or token parity. Archive members before absent and after
a0f4a0ef169c2759537de0c5c82f9c7e55b99c59ce02d414a820e88ae0be1de2.

### Decision 190

`specs/tla/ChecksumBasis.tla` · `intentional_divergence`

Exact upstream TLC 1.8.0 checked all four bounded invariants in 57,493 distinct states. The two alternate
configurations reached the expected WitnessGoal and NoPermanentFalseNegative violations. This model checks
source-specific per-slot basis token behavior. Godot has a distinct byte contract and protects exposed
confirmed history via Session.confirmed_checksums and confirmed_freeze_floor, which the coordinator
incorporates into its cut and each follower rechecks. The actual delayed survivor report on Godot 4.3 and
4.7.2 crossed cut 65, compared the saved frame 60 checksum after recovery (verified_reports 0 to 1), and
preserved the confirmed frontier and canonical current state. This scoped comparison exercises protected
retained history. It does not claim general protocol or token parity. Archive members before absent and after
2bc1216594688db6d8aef01c7bb3ccfd5f85fd60ebdb146b6e7181f2615c5859.

### Decision 191

`specs/tla/ChecksumBasis_BasisBlind.cfg` · `intentional_divergence`

Exact upstream TLC 1.8.0 checked all four bounded invariants in 57,493 distinct states. The two alternate
configurations reached the expected WitnessGoal and NoPermanentFalseNegative violations. This model checks
source-specific per-slot basis token behavior. Godot has a distinct byte contract and protects exposed
confirmed history via Session.confirmed_checksums and confirmed_freeze_floor, which the coordinator
incorporates into its cut and each follower rechecks. The actual delayed survivor report on Godot 4.3 and
4.7.2 crossed cut 65, compared the saved frame 60 checksum after recovery (verified_reports 0 to 1), and
preserved the confirmed frontier and canonical current state. This scoped comparison exercises protected
retained history. It does not claim general protocol or token parity. Archive members before absent and after
f2200872404a3da4e7f82de8e49c9a0a6dcfdaab406f6248465c4392b1859c9d.

### Decision 192

`specs/tla/ChecksumBasis_Witness.cfg` · `intentional_divergence`

Exact upstream TLC 1.8.0 checked all four bounded invariants in 57,493 distinct states. The two alternate
configurations reached the expected WitnessGoal and NoPermanentFalseNegative violations. This model checks
source-specific per-slot basis token behavior. Godot has a distinct byte contract and protects exposed
confirmed history via Session.confirmed_checksums and confirmed_freeze_floor, which the coordinator
incorporates into its cut and each follower rechecks. The actual delayed survivor report on Godot 4.3 and
4.7.2 crossed cut 65, compared the saved frame 60 checksum after recovery (verified_reports 0 to 1), and
preserved the confirmed frontier and canonical current state. This scoped comparison exercises protected
retained history. It does not claim general protocol or token parity. Archive members before absent and after
68adf676ff1c30c6543754c557ee16f83f5e6d630d86096544bccaf27b445561.

### Decision 193

`specs/tla/ChecksumExchange.tla` · `intentional_divergence`

The diff only clarifies the modeled omission of source eviction and documents its receive hard count cap. The
Godot endpoint instead ends on pending-report capacity exhaustion, ignores stale reports outside retained
history, and terminates on a genuine mismatch. See docs/peer-lifecycle.md#game-checksums,
tests/unit/test_peer_lifecycle.gd::checksum_capacity and ::stale_checksum. This disposition does not cover the
distinct ChecksumBasis model. Archive member SHA-256 reviewed
aeb983eb4278223a562e340775047f0aac0dea7da2fb57d91ccec8da8ef17f8b, candidate
6ab09d2c79c88493c43db60aecdf5596254f1c820e6f7141b9b18b04cac73ca5.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/ChecksumExchange.tla

### Decision 194

`specs/tla/CoordinatedReadyDigest.cfg` · `intentional_divergence`

The source model and its witness/mutant configurations model promotion of provisional pre-digest Ready into a
strict-majority quorum. Godot protects the shared safety property with a different barrier: it derives the
authenticated coordinator, requires the previous inventory answer and validates exact cut and digest before
application. It requires an all-survivor certificate for the pending barrier. See docs/peer-lifecycle.md,
addons/fortress_rollback/core/peer_drop_barrier.gd::_receive_commit, and
tests/unit/test_peer_drop_barrier.gd::unreported_window_certificate_is_refused and ::conflicting_certificate.
These Godot tests do not claim TLC state-space coverage. Archive member SHA-256 reviewed absent, candidate
a92e2bd9950556e13915e01aeadf507c325ff326b05a90318a054fc6351d3034.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatedReadyDigest.cfg

### Decision 195

`specs/tla/CoordinatedReadyDigest.tla` · `intentional_divergence`

The source model and its witness/mutant configurations model promotion of provisional pre-digest Ready into a
strict-majority quorum. Godot protects the shared safety property with a different barrier: it derives the
authenticated coordinator, requires the previous inventory answer and validates exact cut and digest before
application. It requires an all-survivor certificate for the pending barrier. See docs/peer-lifecycle.md,
addons/fortress_rollback/core/peer_drop_barrier.gd::_receive_commit, and
tests/unit/test_peer_drop_barrier.gd::unreported_window_certificate_is_refused and ::conflicting_certificate.
These Godot tests do not claim TLC state-space coverage. Archive member SHA-256 reviewed absent, candidate
0c416032330c3b187321cf87ea1f3a7df3dece81aadff029cf76f66868481281.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatedReadyDigest.tla

### Decision 196

`specs/tla/CoordinatedReadyDigest_ProvisionalCounts.cfg` · `intentional_divergence`

The source model and its witness/mutant configurations model promotion of provisional pre-digest Ready into a
strict-majority quorum. Godot protects the shared safety property with a different barrier: it derives the
authenticated coordinator, requires the previous inventory answer and validates exact cut and digest before
application. It requires an all-survivor certificate for the pending barrier. See docs/peer-lifecycle.md,
addons/fortress_rollback/core/peer_drop_barrier.gd::_receive_commit, and
tests/unit/test_peer_drop_barrier.gd::unreported_window_certificate_is_refused and ::conflicting_certificate.
These Godot tests do not claim TLC state-space coverage. Archive member SHA-256 reviewed absent, candidate
5854c41edbba16987163bbc3ccd19111d99e2a840d1ee726c10c031bce8119cf.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatedReadyDigest_ProvisionalCounts.cfg

### Decision 197

`specs/tla/CoordinatedReadyDigest_ProvisionalCountsSafety.cfg` · `intentional_divergence`

The source model and its witness/mutant configurations model promotion of provisional pre-digest Ready into a
strict-majority quorum. Godot protects the shared safety property with a different barrier: it derives the
authenticated coordinator, requires the previous inventory answer and validates exact cut and digest before
application. It requires an all-survivor certificate for the pending barrier. See docs/peer-lifecycle.md,
addons/fortress_rollback/core/peer_drop_barrier.gd::_receive_commit, and
tests/unit/test_peer_drop_barrier.gd::unreported_window_certificate_is_refused and ::conflicting_certificate.
These Godot tests do not claim TLC state-space coverage. Archive member SHA-256 reviewed absent, candidate
f9f37b7b1320124b743a638e888e8a54abceb8ece546e9785152cc7478c163d0.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatedReadyDigest_ProvisionalCountsSafety.cfg

### Decision 198

`specs/tla/CoordinatedReadyDigest_Witness.cfg` · `intentional_divergence`

The source model and its witness/mutant configurations model promotion of provisional pre-digest Ready into a
strict-majority quorum. Godot protects the shared safety property with a different barrier: it derives the
authenticated coordinator, requires the previous inventory answer and validates exact cut and digest before
application. It requires an all-survivor certificate for the pending barrier. See docs/peer-lifecycle.md,
addons/fortress_rollback/core/peer_drop_barrier.gd::_receive_commit, and
tests/unit/test_peer_drop_barrier.gd::unreported_window_certificate_is_refused and ::conflicting_certificate.
These Godot tests do not claim TLC state-space coverage. Archive member SHA-256 reviewed absent, candidate
3a12e232e8bb7121e77b43555ecdf4719bfac5609c3e7e2f1c8d441277f5f853.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatedReadyDigest_Witness.cfg

### Decision 199

`specs/tla/CoordinatorFailover.cfg` · `intentional_divergence`

The model studies fallback-coordinator liveness and single-cut safety when an acting authority can compete.
Godot retains one authorized coordinator and terminates the pending barrier on silence.
docs/oracle-p2p.md#coordinator-silence-on-the-version-6-candidate compares the same schedule on both Godot
pins and v6, checking original confirmed rows and lack of a Godot freeze. It provides an observed policy
boundary, not a product claim about competing authorities. Archive member SHA-256 reviewed absent, candidate
15d7d6bf9579a4dbe82447a1686e88b822068cf8570867e20f1284653db05bd7.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatorFailover.cfg

### Decision 200

`specs/tla/CoordinatorFailover.tla` · `intentional_divergence`

The model studies fallback-coordinator liveness and single-cut safety when an acting authority can compete.
Godot retains one authorized coordinator and terminates the pending barrier on silence.
docs/oracle-p2p.md#coordinator-silence-on-the-version-6-candidate compares the same schedule on both Godot
pins and v6, checking original confirmed rows and lack of a Godot freeze. It provides an observed policy
boundary, not a product claim about competing authorities. Archive member SHA-256 reviewed absent, candidate
6823d00773d424f224715869351f642ed42fbbf60a37816deaa4c3afcc6b3d09.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatorFailover.tla

### Decision 201

`specs/tla/CoordinatorFailoverCompeting.cfg` · `intentional_divergence`

The model studies fallback-coordinator liveness and single-cut safety when an acting authority can compete.
Godot retains one authorized coordinator and terminates the pending barrier on silence.
docs/oracle-p2p.md#coordinator-silence-on-the-version-6-candidate compares the same schedule on both Godot
pins and v6, checking original confirmed rows and lack of a Godot freeze. It provides an observed policy
boundary, not a product claim about competing authorities. Archive member SHA-256 reviewed absent, candidate
ad30bd38cac4e511de820b5ca43bd239f23630675c66121d475928625302a282.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatorFailoverCompeting.cfg

### Decision 202

`specs/tla/CoordinatorFailoverCompeting.tla` · `intentional_divergence`

Exact archive CoordinatorFailoverCompeting and the candidate CoordinatorFailover dependency passed
SafetyInvariant across 280,400 distinct states using the upstream TLC 1.8.0 invocation with deadlock checking
disabled. A standalone deadlock-enabled run diagnoses a reachable split Ready deadlock, which is outside the
checking claim. The Godot peer-drop policy has no fallback authority after coordinator silence. In the exact
v6 coordinator-failover qualification the source committed cut 5 via fallback while all three Godot survivors
timed out, preserving rows 0–4. Godot does not enter this source model’s competing authority state space.
Archive members before absent and after e62c00de6057225dc56f372222c07e559892b22b89f0d8365af9a3f1037bd70a.

### Decision 203

`specs/tla/CoordinatorSplitView.cfg` · `intentional_divergence`

The model and local-view counterexample use nine voters, strict-majority Ready and competing local participant
views. Godot retains a frozen roster, rejects an altered roster digest and uses all-survivor certification
after its automatic quorum check. See docs/peer-lifecycle.md#the-coordinated-drop and
tests/unit/test_peer_drop_barrier.gd::even_split_fails_closed, ::minority_split_continues and
::skewed_roster_proposal_is_refused. The local evidence covers the safety goal, not the exact source model
topology. Archive member SHA-256 reviewed absent, candidate
5601ec81b8e53ad4b2d93d740edd9526afebe1d2884d9fe9857f4c564a358c69.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatorSplitView.cfg

### Decision 204

`specs/tla/CoordinatorSplitView.tla` · `intentional_divergence`

The model and local-view counterexample use nine voters, strict-majority Ready and competing local participant
views. Godot retains a frozen roster, rejects an altered roster digest and uses all-survivor certification
after its automatic quorum check. See docs/peer-lifecycle.md#the-coordinated-drop and
tests/unit/test_peer_drop_barrier.gd::even_split_fails_closed, ::minority_split_continues and
::skewed_roster_proposal_is_refused. The local evidence covers the safety goal, not the exact source model
topology. Archive member SHA-256 reviewed absent, candidate
58f689cb361ed0059fd2c16b8d3f5c813bc9db3401237663fb7998c1f8cb4c0a.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatorSplitView.tla

### Decision 205

`specs/tla/CoordinatorSplitViewLocal.cfg` · `intentional_divergence`

The model and local-view counterexample use nine voters, strict-majority Ready and competing local participant
views. Godot retains a frozen roster, rejects an altered roster digest and uses all-survivor certification
after its automatic quorum check. See docs/peer-lifecycle.md#the-coordinated-drop and
tests/unit/test_peer_drop_barrier.gd::even_split_fails_closed, ::minority_split_continues and
::skewed_roster_proposal_is_refused. The local evidence covers the safety goal, not the exact source model
topology. Archive member SHA-256 reviewed absent, candidate
3a6f01998a6da44fd67a8b19e131935b7a1afff5978917c33d9c40f902074584.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/specs/tla/CoordinatorSplitViewLocal.cfg

### Decision 206

`specs/tla/README.md` · `intentional_divergence`

The upstream model inventory adds converged checksum basis, fixed fallback/competing coordination, split-view
membership, and provisional Ready digest entries. It also rewrites the documented DoubleFailureRelay reference
around sequenced post-prune floor rounds and specifies its topology limits. Exact candidate
Ready/SplitView/Fallback configurations passed 120,516/12/19,840 distinct states, and the prior independent
candidate checksum/competing-authority checks passed bounded safety with documented scope. Godot has its own
fixed-coordinator, all-survivor, confirmed-high-water policy and owns a distinct byte contract rather than
these Rust-only proof internals. Its verified candidate spectator model applies to the actual independent
playback adapter; coordinator failover and post-cut checksum delay preserve the observed original retained
prefix with the product policy difference. Model logs
ae81fd93325169037d110cea1a3cd55694cd8a075fc7dc21c5e246f7bee835a2/e871c15ebbc729cdbe30541811d63bf468218a2d7c4b5b0ec6513fae22afd5eb/3dc5f09996186faebdcc56fbe7cc81dccff2ab64ded2372a3d3dd13217c86ccc;
candidate failover 805352d06bfd6119d124d8a2ce03fea55964a5392974b3449a42b256be4a2cd1; paired spectator
db16ff837697fc608356e56fedcfaf3d774e46b34b21e1f8475f42cb74356e6a/7acfd180aa2757313ad9bace045192875e5a1a415a621457be37a641be67cfee.
Archive member SHA-256 reviewed 9736aa9b244bcc18ef975d58b7d19fa282363b2fc6e7c13776d50a0189d80684, candidate
4cc81b414798ccab32469753e8fcd4b9d861e7fe1f3f6cb1e3cec24c805beb85.

### Decision 207

`src/checksum.rs` · `inapplicable`

The source keeps checksum byte results while switching Rust Serde to one encode pass and deferring Fletcher-16
modulo reduction in 4096-byte blocks. The archive lib suite passed
compute_checksum_serializes_the_state_exactly_once and prop_fletcher16_matches_bytewise_reference. The
GDScript public boundary takes 16-byte checksums supplied by the game and contains neither Rust Serde
re-encoding nor a Fletcher-16 checksum implementation. Production peer checksum exchange validates size, frame
and ownership in peer_checksums.gd, and the v6 receipts compare the callback-owned checksum for
checksums_match, checksums_repair and checksums_diverge on both pins. Archive lib log
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. P2P receipts
61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366/38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd.
Archive member SHA-256 reviewed 1f878fb8e5c0c861a055f53f071c62a0d202b0fa6198200768997e0dc65d85d1, candidate
1e866ff6f782f136c11811e1551afd5bb0e069bb3d3254705dec2f564c98fd1d.

### Decision 208

`src/error.rs` · `intentional_divergence`

The source adds SpectatorStreamEnded with the exact first truncated frame after all hosts disconnect and any
buffered tail is consumed. The source lib suite passed the all-hosts-disconnect and late-final-input
truncation cases. Godot separates authenticated clean finish (drain tail) from known selected-source loss
(stop before any further buffered callback, keep a terminal cause). test_signalfish_spectator_relay.gd
exercises selected and foreign departure, including startup/re-entry. Both Godot pins passed the existing
suites, result hashes 8bc9c2d13f66737fea1d951031ad97858f61c73b747efdcb1425de8ccd0cd738,
c1503bc55e621d8be0afc119ebb48b9efc85eb94d8d2b27cca7efe8a7ffbb96d. Reviewed archive member SHA-256
c157f602678b05e2638de48c325dde4b8ee9122b51dc852b7a1693719c534222 and candidate
48540598db48b712f2d36a3b49083e9213fd47184f3f4ff2bba6f3422f7deb14.

### Decision 209

`src/hash.rs` · `intentional_divergence`

The source canonicalizes Rust scalar integer Hasher writes to fixed-width little endian and documents its
native slice caveat. Godot encodes application byte values explicitly and uses separately specified
byte-vector hashes; it has no Rust Hash dispatch or native-slice domain. docs/experiments/integer-encoding.md
and docs/contracts.md specify that boundary. The candidate cached test binary passed seven targeted
transport/representation checks, log SHA-256 2099f8032f05ed9af532969ddbb53e8ef4a56831bd9e5e9da7b63fe937de90c7.
Archive member SHA-256 before 77c173f1e29e6022262ddc2325604adec806392ea7b5d84d4e32eb789fc03bfe, after
bb6ac2bc90b509f74a0727bee94fa76089277cf28b50d8c466bd62eccdc96396.

### Decision 210

`src/input_queue/mod.rs` · `intentional_divergence`

Candidate raw queue repeated 711 cases and 8,353 operations on both pinned Godot engines. The optional Godot
queue requires each addressed overlap byte to remain verifiable before accepting a backfill suffix. With
capacity 8 and rows 0–2 installed, both Godot pins retain 1–2 after discard, refuse the overlapping 0–3 chunk,
and still lack row 3. The exact upstream candidate test evicted_overlap_prefix_is_skipped_for_backfill_suffix
accepts and installs row 3 on that shape. Native links the candidate implementation; the GDScript backfill
retains its existing conservative policy. Candidate source SHA-256
05313bcbd67562815f36b8d96bdd283b1ad609289320c88fb78f747094417287 and reviewed source SHA-256
537ae9aab97af4cdfb7b0d84b738f56879ee387136c073b40eba1ff476f4a776. Godot 4.3 probe log SHA-256
b4e65ff026c2246c17c44a0e4508c09bc5980c2ed6bb857bed80e5ca83bb6e98; Godot 4.7.2 probe log SHA-256
dde89cfd84d1e605d31106c2117ea9b6ec6004f33e66ebdc98145ff845b7f099.

### Decision 211

`src/lib.rs` · `intentional_divergence`

This root export changes protocol version and Rust feature wiring, adds the early-return request macro and
opt-in socket metrics, and adds Kani-only ring index proofs. The port preserves fallible typed request
completion and bounded frame-indexed rings through its own APIs and independent representation controls. The
upstream macro, generic Rust metrics and feature export ABI do not belong to the Godot surface. Paired actual
v6 Rust/Godot comparison passed all 67 scenarios on Godot 4.3 and 4.7.2, including loss, reordering, queue
wrap, checksums and lifecycle events in the scoped profiles. Source packet profiles and Godot protocol frames
are compared in their own representations. Receipt SHA-256s
61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Candidate all-library 2,103-test output
SHA-256 1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Archive member SHA-256 before
fbef49cf724dd6cf4b62d8f842158a264ae34044b7afd1eb323fb0dcabf758d7, after
4101b6c9d9532274060adb5449e4ef36bdc112b6f437b877c586df71baf99680.

### Decision 212

`src/metrics.rs` · `intentional_divergence`

The Rust SocketMetrics counters measure datagrams offered to or taken from UDP, Tokio or custom sockets, and
distinguish accepted sends from delivery. Godot's SignalFish relay exposes its bounded pending and received
packet/byte gauges plus rejection, ignored, overflow and last-code fields through
transport/signalfish_relay.gd status(). The SDK relay does not expose Rust's cumulative socket counter schema.
tests/unit/test_signalfish_relay.gd checks queue accounting and refusal. Exact candidate library selection ran
the new socket metric case and the diagnostic macro cases, 8 passed and 0 failed (log SHA-256
385a7998e5236b607cfab24ed8afc70ae5a6e2e14ef3c0f6a7bed577937a7c41). Both exact candidate Godot P2P receipts for
Godot 4.3 and 4.7.2 passed all 67 scenarios. Reviewed member SHA-256
f08fa00c9bcecd85b46ad9e326fbb8d328d482d9bcd05de6682f2698e0d231c7. Candidate member SHA-256
353ae49a655d83c3f6ec40908bf7becc6b637115e4fa67cd5623cdee8927c041.

### Decision 213

`src/network/chaos_socket.rs` · `intentional_divergence`

The Rust ChaosSocket adds cumulative adapter totals, queue age and separate ready/in-flight/reordering
capacity accounting. Godot fault qualification owns explicit delivery schedules and observed endpoint counters
without adopting the upstream wrapper or claiming its queue-age API. Paired actual v6 Rust/Godot comparison
passed all 67 scenarios on Godot 4.3 and 4.7.2, including loss, reordering, queue wrap, checksums and
lifecycle events in the scoped profiles. Source packet profiles and Godot protocol frames are compared in
their own representations. Receipt SHA-256s 61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. The candidate cached test binary passed
seven targeted transport/representation checks, log SHA-256
2099f8032f05ed9af532969ddbb53e8ef4a56831bd9e5e9da7b63fe937de90c7. Archive member SHA-256 before
4aa517d44e4ec4c5941cf3a781a9c0d6b193df919f0891631f82b53eca70f2ae, after
dc9d9afc53147c5bdd61081415859c956c4c5cb8183d2a6f65d536b2f10f0e35.

### Decision 214

`src/network/codec.rs` · `intentional_divergence`

The Rust explicit wire codec adds v6 profile, bounded participant/snapshot fields, exact compatibility gating,
and reusable wire digests. Godot has a separate fixed-width protocol and rejects unsupported layouts in its
own codecs. The raw upstream fields and past exact identities remain observable in the source selection
receipts, including wire negative controls. Full hot join is tracked as excluded under #50. Paired actual v6
Rust/Godot comparison passed all 67 scenarios on Godot 4.3 and 4.7.2, including loss, reordering, queue wrap,
checksums and lifecycle events in the scoped profiles. Source packet profiles and Godot protocol frames are
compared in their own representations. Receipt SHA-256s
61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. The candidate cached test binary passed
seven targeted transport/representation checks, log SHA-256
2099f8032f05ed9af532969ddbb53e8ef4a56831bd9e5e9da7b63fe937de90c7. Archive member SHA-256 before
41ff7da933ffadba7956b61fe57371e71aadec46052cdabbe199962017a40180, after
541ecdd64e20e23fe21c6e7df3cc52b2f5adc03bcf88749e759ed2cb6b7ece43.

### Decision 215

`src/network/compression.rs` · `intentional_divergence`

Source XOR delta encoding gains queued-output RLE and reusable intermediate allocation. The source check
verifies byte identity and reused scratch. Godot encodes bounded raw input records per docs/input-exchange.md
and compares decoded values, not Rust compression bytes. Paired actual v6 Rust/Godot comparison passed all 67
scenarios on Godot 4.3 and 4.7.2, including loss, reordering, queue wrap, checksums and lifecycle events in
the scoped profiles. Source packet profiles and Godot protocol frames are compared in their own
representations. Receipt SHA-256s 61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. The candidate cached test binary passed
seven targeted transport/representation checks, log SHA-256
2099f8032f05ed9af532969ddbb53e8ef4a56831bd9e5e9da7b63fe937de90c7. Archive member SHA-256 before
a8e0c1d55f3a193d2314bef73e1d9b60c3d8da32fd85e531cba71d43069ca3cf, after
393e0e763a3173f5c067e204aaf8384364b7050168b76d7ed1c286e9f8f8a45d.

### Decision 216

`src/network/messages.rs` · `intentional_divergence`

The Rust v6 messages add participant binding, terminal epochs, donor identity/range and per-slot checksum
basis carried through snapshot import. Godot retains its independently bounded roster, packet layout,
protected exposed frontier and explicit unsupported hot join. Scoped source drop/failover receipts retain the
full v6 raw fields and do not require cross-wire interoperability. Paired actual v6 Rust/Godot comparison
passed all 67 scenarios on Godot 4.3 and 4.7.2, including loss, reordering, queue wrap, checksums and
lifecycle events in the scoped profiles. Source packet profiles and Godot protocol frames are compared in
their own representations. Receipt SHA-256s 61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Candidate all-library 2,103-test output
SHA-256 1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Archive member SHA-256 before
c8fd5d21737d219d9931f36f4bea949d806cb8f65baa407b0e00ad9f422e8997, after
f92d3a0c8f71066ae38d5e9bf07a00e47bd113d7ec5ccc195a3db4b120f16630.

### Decision 217

`src/network/protocol/event.rs` · `intentional_divergence`

Source public observations distinguish a peer-authored Goodbye from a locally detected timeout or backpressure
disconnect. Godot owns the equivalent lifecycle distinctions via its typed events and terminates or
coordinates freeze by endpoint policy. Its emitted event names and ordered production trace are separate from
Rust enum/display names. Paired actual v6 Rust/Godot comparison passed all 67 scenarios on Godot 4.3 and
4.7.2, including loss, reordering, queue wrap, checksums and lifecycle events in the scoped profiles. Source
packet profiles and Godot protocol frames are compared in their own representations. Receipt SHA-256s
61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Candidate all-library 2,103-test output
SHA-256 1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Archive member SHA-256 before
87331a1335039c619014fa6c8df660139698726743ded7cf3b0c1c9b8d0b8684, after
9da9a5eaca7a51052fd4183965b430eba7413a1f3f313a9f2d9c05b375cf4068.

### Decision 218

`src/network/protocol/input_bytes.rs` · `intentional_divergence`

Source serializes generic inputs and now borrows a canonical ascending-slot vector, retains disconnected
blanks and reports structured Rust serialization failures. The port uses explicit-width input byte samples,
ordered by slot, and its own bounded validation. The actual port controls packet row ownership and slot order.
The candidate cached test binary passed seven targeted transport/representation checks, log SHA-256
2099f8032f05ed9af532969ddbb53e8ef4a56831bd9e5e9da7b63fe937de90c7. Paired actual v6 Rust/Godot comparison
passed all 67 scenarios on Godot 4.3 and 4.7.2, including loss, reordering, queue wrap, checksums and
lifecycle events in the scoped profiles. Source packet profiles and Godot protocol frames are compared in
their own representations. Receipt SHA-256s 61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Archive member SHA-256 before
1089891d65ad68107c80fea6834ef41d5a1b6eb499de7001b800b1999011e04d, after
a0560e47e27f97cd6ccda1b54f662b36422eccab85fa4e58182c288a196ec1af.

### Decision 219

`src/network/protocol/mod.rs` · `intentional_divergence`

Source v6 endpoint changes include exact ACK classification, retained input and checksum bounds, split
Goodbye/timeout, checksum basis observations, capability checks during drop, and packet status snapshot reuse.
The Godot protocol retains its own layout, bounded fixed-width buffers and lifecycle authentication.
Same-source Rust packet behavior, emitted Godot packets, and their ordered logical events are separately
validated. Source-only membership fallback and checksum basis do not become Godot policy through this pin.
Paired actual v6 Rust/Godot comparison passed all 67 scenarios on Godot 4.3 and 4.7.2, including loss,
reordering, queue wrap, checksums and lifecycle events in the scoped profiles. Source packet profiles and
Godot protocol frames are compared in their own representations. Receipt SHA-256s
61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Candidate all-library 2,103-test output
SHA-256 1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Archive member SHA-256 before
f22f8648d20d4abd6aa70eae90231b7c7e7a0d8af2211985206c1821736b67cf, after
0e9f53032736ac9823f2ce22b59b3056ac8cc0f8667aef68c3f2cc3cd14d9e49.

### Decision 220

`src/network/socket_receive.rs` · `intentional_divergence`

The backend counts raw datagrams, rejected decodes, allocation refusals and per-drain receive caps in the same
Rust helper for UDP/Tokio. Godot drains its engine/SDK transports through bounded queues and checks decoder
and transport counters at its own boundary. Its port neither calls Rust UDP nor conflates handled gameplay
with raw datagrams. Paired actual v6 Rust/Godot comparison passed all 67 scenarios on Godot 4.3 and 4.7.2,
including loss, reordering, queue wrap, checksums and lifecycle events in the scoped profiles. Source packet
profiles and Godot protocol frames are compared in their own representations. Receipt SHA-256s
61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Candidate all-library 2,103-test output
SHA-256 1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Archive member SHA-256 before
6e16e39446c1991fe27c89e735bcbd4aea605ddeb21a9fc616dac35a8172a69b, after
7c1325d51c4e0afc1438a802ed4d897aec6b3ccc91d3e51574608abf46164895.

### Decision 221

`src/network/tokio_socket.rs` · `intentional_divergence`

The optional native Rust Tokio UDP implementation reports accepted writes, send failures and actual receive
processing. It is absent from the default-feature-free Godot extension. Godot delivers via engine/SDK
adapters, and exact candidate native and Web packages all passed the live-match and control matrix. Source
native Cargo feature matrix and network workflow ran separately. Exact candidate CI Network Tests 46046809651
passed the Linux, macOS, Windows and Docker jobs. The Linux smoke log reported 62 passed and 216 skipped.
Archive member SHA-256 before 002fc47d0f70f3b5bece997278745ae8ad72ed4c8cee09304dda4c34e69ebf3b, after
b3bcc357556fb3bb550a36e52b285c950f0b862c38c2f9712ba2aca2fc5b4a3e.

### Decision 222

`src/network/udp_socket.rs` · `intentional_divergence`

Source raw UDP tracks actual successful datagrams and receives, reports oversized output, and uses bounded
receive. Godot raw packet processing is owned by its injected transport or SignalFish clients with distinct
SDK acceptance/pressure counters. Exact Rust source loopback metrics and the shipped Godot and platform
qualification witnesses passed. The candidate cached test binary passed seven targeted
transport/representation checks, log SHA-256 2099f8032f05ed9af532969ddbb53e8ef4a56831bd9e5e9da7b63fe937de90c7.
Paired actual v6 Rust/Godot comparison passed all 67 scenarios on Godot 4.3 and 4.7.2, including loss,
reordering, queue wrap, checksums and lifecycle events in the scoped profiles. Source packet profiles and
Godot protocol frames are compared in their own representations. Receipt SHA-256s
61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Archive member SHA-256 before
1a385167ec393424cef7bb812967556c1fe80ea6e44edba8ed3aa88f8687ccdd, after
b135c358a693166fcf76b7e8d08d9a84745dd86b073ed44f2fb2780c038ec464.

### Decision 223

`src/network/wire_golden_v1.rs` · `intentional_divergence`

All 23 frozen upstream byte arrays match the old archive exactly. The candidate adapts the test constructors
to the present structs and tests historical header rejection. The exact candidate Rust library run passed
2,103 tests with default features disabled, log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Godot uses its independent protocol, as
scoped in docs/reference/p2p-profiles.md. The Rust observers preserve selected v2/v6 field shapes and paired
behavior across the archive switch. They do not republish the upstream byte arrays as Godot packet fixtures.
Old archive member SHA-256 f0ebbd0096ced3fdb383ab31d50e47f204f0d2aa3a253a24f66850ecb170cd79 and candidate
95d4b1c2c375553a3f4ab2da0a7e75e165c6ec148e8d5747aa5f6441f8b0b4a2.

### Decision 224

`src/network/wire_golden_v2.rs` · `intentional_divergence`

All 23 frozen upstream byte arrays match the old archive exactly. The candidate adapts the test constructors
to the present structs and tests historical header rejection. The exact candidate Rust library run passed
2,103 tests with default features disabled, log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Godot uses its independent protocol, as
scoped in docs/reference/p2p-profiles.md. The Rust observers preserve selected v2/v6 field shapes and paired
behavior across the archive switch. They do not republish the upstream byte arrays as Godot packet fixtures.
Old archive member SHA-256 32c0d57b62295524837d3b3158128f04bfe580a6f8477efa7a63283cd06dd9bc and candidate
7a21e94dc933ece3164e96701b0f6ca7b896716b669f6b6cb71298c71db11ea2.

### Decision 225

`src/network/wire_golden_v3.rs` · `intentional_divergence`

The candidate adds the released v3 fixtures as a Rust codec version-rejection suite. The exact candidate Rust
library run passed 2,103 tests with default features disabled, log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Godot uses its independent protocol, as
scoped in docs/reference/p2p-profiles.md. The Rust observers preserve selected v2/v6 field shapes and paired
behavior across the archive switch. They do not republish the upstream byte arrays as Godot packet fixtures.
Old archive member SHA-256 absent and candidate
9b583a6b7a4f1fbc4c0823980f83cb7c8bbed72c0063d665b0ceb0841ee34e79.

### Decision 226

`src/network/wire_golden_v4.rs` · `intentional_divergence`

The candidate adds the released v4 fixtures as a Rust codec version-rejection suite. The exact candidate Rust
library run passed 2,103 tests with default features disabled, log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Godot uses its independent protocol, as
scoped in docs/reference/p2p-profiles.md. The Rust observers preserve selected v2/v6 field shapes and paired
behavior across the archive switch. They do not republish the upstream byte arrays as Godot packet fixtures.
Old archive member SHA-256 absent and candidate
1de065f6c9dfda704e9d176f4800f5aa20b8bf86bc5fbbc286075c40d29b52b1.

### Decision 227

`src/network/wire_golden_v5.rs` · `intentional_divergence`

The candidate adds the released v5 fixtures as a Rust codec version-rejection suite. The exact candidate Rust
library run passed 2,103 tests with default features disabled, log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Godot uses its independent protocol, as
scoped in docs/reference/p2p-profiles.md. The Rust observers preserve selected v2/v6 field shapes and paired
behavior across the archive switch. They do not republish the upstream byte arrays as Godot packet fixtures.
Old archive member SHA-256 absent and candidate
1d52f93b9f91b076a81d312c4e9145233997b9a99c3af47fac287f4a83794c62.

### Decision 228

`src/network/wire_golden_v6.rs` · `intentional_divergence`

The candidate exact v6 suite pins current Rust encoded bytes and verifies recognition of feature-disabled
hot-join messages. The exact candidate Rust library run passed 2,103 tests with default features disabled, log
SHA-256 1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Godot uses its independent protocol,
as scoped in docs/reference/p2p-profiles.md. The Rust observers preserve selected v2/v6 field shapes and
paired behavior across the archive switch. They do not republish the upstream byte arrays as Godot packet
fixtures. Old archive member SHA-256 absent and candidate
7e1b97f26bfc25cd6293813ccbe936fbd6bad5dcdfdd17d1f667905961e324e9.

### Decision 229

`src/replay.rs` · `intentional_divergence`

The candidate source recorder refreshes speculative checksums after rollback, and its generic Replay decoder
bounds the player domain and cumulative zero-sized inputs. The native crate retains that behavior directly.
Godot uses a separate FRRP codec, limits rosters to 2 through 8 and input widths to positive 1 through 65536
bytes, and supports status and optional v6 terminal evidence. addons/fortress_rollback/core/replay.gd
validates those dimensions before decoding rows. Candidate upstream lib tests include
from_bytes_rejects_player_counts_outside_the_u16_domain,
replay_from_bytes_rejects_zero_sized_count_bomb_from_header, and
replay_serialization_uses_fixed_little_endian_wire_bytes (2103 passed, log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c). The real paired replay launchers check
corrected checksum histories, decoded input/status and state, both Godot interfaces, and all three FRRP
versions. The native Rust byte layout remains separate from Godot FRRP. Verified paired replay receipt SHA-256
values: 4.3 candidate ef58d9c9eb8a50b8576a60db0cb4f5a2a49b0c55adb6d62afef9f9fc6b5f29d7, 4.3 historical
c0bcf1ae4dc2dfabb633af5f5dfc4d4324fa77bc9e8fde224f8a8f9ec7e0756b, 4.7.2 candidate
62a9a153a8fb3d17f086c4ed7523e73b72b8d983cd2eef49d8b5294ae3cb68f6, 4.7.2 historical
0447e717a67380975c8bc040be21d3490c8bf115d24d2e66bf3b5de401b812e4. Historical archive member SHA-256
9f39733c5648386676c35a46c9aefdd32f9528c9504f53ceb6a4a513cda9c00b. Candidate archive member SHA-256
6764540cf44693fcb6d8d0f577bc7ea61d495ce11908350aefe50bccf0f73fa7.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/src/replay.rs

### Decision 230

`src/rle.rs` · `intentional_divergence`

The upstream portable RLE implementation uses one-pass reservation below a bound and retains exact
large-buffer sizing, with byte encoding preserved. Godot does not use source XOR/RLE input transport, uses
explicit packed rows, and validates its own exact lengths. Candidate all-library 2,103-test output SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Paired actual v6 Rust/Godot comparison
passed all 67 scenarios on Godot 4.3 and 4.7.2, including loss, reordering, queue wrap, checksums and
lifecycle events in the scoped profiles. Source packet profiles and Godot protocol frames are compared in
their own representations. Receipt SHA-256s 61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Archive member SHA-256 before
4e732995ae60b3f233d75d23cf3d09644c2049217947190fd7d218756b4ca63f, after
70a06589e111e291395d7d54be74d73edaaa4843693b6cadc6a9e7fe7faf4e00.

### Decision 231

`src/rle/varint.rs` · `intentional_divergence`

A dependency-free source LEB128 varint seam supports the upstream RLE codec proofs. Godot input packets use
bounded fixed-width encoding and need no varint or compressed decoder; cross-runtime packets are expressly
outside the compared scope. Candidate all-library 2,103-test output SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Paired actual v6 Rust/Godot comparison
passed all 67 scenarios on Godot 4.3 and 4.7.2, including loss, reordering, queue wrap, checksums and
lifecycle events in the scoped profiles. Source packet profiles and Godot protocol frames are compared in
their own representations. Receipt SHA-256s 61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Archive member SHA-256 before absent, after
245a66f93b3d44fb415c499fb661d8da582557273b56445dd7804d3f89b29143.

### Decision 232

`src/rng.rs` · `inapplicable`

The exact archive files differ only inside the Rust test module tests. Removing that module yields the same
dependency source at both pins. The Godot/native packages link the released crate, and its 2,103
no-default-feature library tests passed against the candidate archive. Reviewed member SHA-256
66f8a39da14853751ef5af07a4ca650d5991ee296c0d65e0022c14ce816cebbd and candidate member SHA-256
74e5e09fedb78de25987ea53ec37ec7f50abc648c7056048455e196f6cbd3685. Candidate complete build/test log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/src/rng.rs

### Decision 233

`src/sessions/checksum_basis.rs` · `intentional_divergence`

The new Rust module owns per-slot converged freeze-boundary terms, frame tokens, bounded folding, and adopted
snapshot basis. The archived source basis tests pass and TLC checked 57,493 distinct states for the four
bounded invariants. The Godot wire carries the game checksum, not a converged Rust basis token. Godot’s
confirmed freeze floor preserves exposed history. The actual delayed surviving-peer report on both Godot pins
crossed cut 65, verified frame 60 after recovery (verified_reports rose 0 to 1), and preserved
confirmation/canonical state in session279 delayed-survivor-checksum logs. Independent candidate oracle
preserves Rust token width and source-specific semantics. Source lib log
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Exact prior model evidence digest
e1f6197ea321fbfc537fad12921af730fe5dcf2f6a5bbfc1292417bb095f7180. Archive member SHA-256 reviewed absent,
candidate 106e776e1726d0540abfbe398a3b6259bf8028ad81ed0365f5c9881039e35c98.

### Decision 234

`src/sessions/config.rs` · `intentional_divergence`

The diff clarifies bounded checksum reports, zero-speed catch-up after all hosts leave, and quorum/witness
requirements. Godot caps pending checksum reports per endpoint and exercises the capacity diagnostic and
missing-quorum timeout. Godot requires positive catch-up speed and distinguishes authenticated clean
completion from selected-source loss. There is no API equivalent of the source application-directed removal
bypass. Both Godot pins passed the existing suites, result hashes
8bc9c2d13f66737fea1d951031ad97858f61c73b747efdcb1425de8ccd0cd738,
c1503bc55e621d8be0afc119ebb48b9efc85eb94d8d2b27cca7efe8a7ffbb96d. Both Godot pins passed the existing suites,
result hashes 5ae23872e4283f2756ca4a2aa7d1e8abddc253ce1c09eb1d559111050516fdcf,
43d5d9a4534d6d92807518fcbfce92f7ef8a40c506571b3ca4e4c3a827f6ace3. Reviewed archive member SHA-256
4c22a58ae1baa06527380dbb7a553d142a69ee0078d8c48a5f96cd1cfe4a4552 and candidate
887ee9ca471499c62663ee76371699199014fb7a4d41c6fbbd9e2d1b3ec86e75.

### Decision 235

`src/sessions/hot_join.rs` · `intentional_divergence`

Source snapshot capture checks encoded allocation budget, adds certified exclusions and bounded checksum
basis, and validates the incoming basis/bridge before mutation. Godot fixes membership for a match and does
not transfer game state to a new player or adopt a prior freeze basis. Hot join and reactivation are
explicitly excluded by docs/supported.md and tracked in #50. The candidate source-only
hot_join_schedules_replay_with_full_oracle passed, and i686 and aarch64-QEMU upstream CI passed oversized
snapshot failure, witnessless refusal and explicit-removal rejoin. The candidate spectator comparison
selectively enables Rust hot-join only to initialize a source reserved slot for status forwarding, with no
reactivation claimed by docs/spectators.md. Spectator receipts
db16ff837697fc608356e56fedcfaf3d774e46b34b21e1f8475f42cb74356e6a/7acfd180aa2757313ad9bace045192875e5a1a415a621457be37a641be67cfee.
Upstream source CI run https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046809665.
Archive member SHA-256 reviewed b1b2d74c3f5ca04ee9a2947eff8a6463ae585b6fa54cca4da0c90aebbd8952c8, candidate
ec3310e97ef08285edbd5a85f5d25ff48a65024ad585c0371a1662b7b044e209.

### Decision 236

`src/sessions/p2p_session.rs` · `intentional_divergence`

The archive change includes bound drop membership/cuts, fallback authority, terminal epoch and provisional
READY fencing, original-history donor relay, post-prune confirmation folds, retained/sparse correction,
recovery-only input service, live replay checksum repair, hot-join snapshot/rearm rules, spectator forwarding,
and upstream allocation/diagnostic ownership. Fixed-membership byte gameplay ran 67 archive-selected scenarios
twice on both pins. Grouped drop comparison retained changing rows, statuses and canonical prefixes under lost
inventory/history/commit/ack and refused at the deadline. The five-endpoint silence case preserves the same
original rows 0–4, with the source certifying cut 5 via fallback and Godot ending the barrier. GDScript uses a
fixed coordinator, all surviving certificates, fixed roster, owned dense snapshots, separate diagnostics and
spectator envelope, and independently supports recovery without another sample. Hot join, sparse source
checkpoint search and exact source terminal epoch/fallback behavior sit outside the Godot comparison envelope.
The source separates explicit Goodbye, which certifies the receiver immediately, from witnessless automatic
timeout, which emits neither PeerDropped nor Disconnected, leaves confirmation unchanged, and refuses further
advance in both two-endpoint and multi-handle one-remote cases. The Godot _live_survivors()==0 exception
expressly documented in docs/peer-lifecycle.md#the-coordinated-drop still allows a one-member timeout freeze
after verifying the retained local history. test_peer_drop_history.gd::last_survivor_receipts plays through
physical silence using two encoded peers, certifies cut 5 and cut 8 with three extra actual receipts, advances
another 12 turns and independently checks canonical states, replay bytes and disconnected status.
test_peer_drop_multi_slot.gd verifies both covered grouped continuation and refusal of incomplete grouped
history. This is a deliberate legacy limitation. Matching the newer witness rule and qualification of
symmetric two-endpoint partitions remain in #48. Fresh paired Godot results SHA-256
ab557a534dfe9b5e2172820665dba8d6684e5f0f959952c393cf1267af5022e9/36b5b829789fbf1f734cedf34a8711e8a299eff106551d0dd83ade85ca1d8c02.
67-case receipts
61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366/38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd.
Grouped drop f9d1d94c89c0e44162cc9eb7dd1a8802f600549b161d2e00c4a9645ee6a2b58c. Failover
805352d06bfd6119d124d8a2ce03fea55964a5392974b3449a42b256be4a2cd1. Recovery-only replay receipts
ef58d9c9eb8a50b8576a60db0cb4f5a2a49b0c55adb6d62afef9f9fc6b5f29d7/62a9a153a8fb3d17f086c4ed7523e73b72b8d983cd2eef49d8b5294ae3cb68f6.
Archive member SHA-256 reviewed 08c0fca863f0e3a0ddd19aae285eaee427fb614f0ccab5b7e95fe42fe92abc2d, candidate
5dce451f2f1ce4e05fe0bcc5c6a8cd7b26fe38febfed26eb448196eb5f92ec4f.

### Decision 237

`src/sessions/p2p_spectator_session.rs` · `intentional_divergence`

Source treats Goodbye and disconnect as host retirement after all events from the same poll, drains the
playable prefix including when configured catch-up speed is zero, then returns SpectatorStreamEnded at the
missing frame. The archive lib suite passes same-poll Goodbye/row ordering, later-poll truncation and
zero-catch-up terminal drain. Godot requires positive catch-up speed, uses authenticated row/END ordering with
clean final-tail release, and stops on explicitly signaled host loss. Live redundant host migration and wire
handshake retain separate #47/#49 scope. Candidate selected model/runtime repeats reorder, stream delay,
roster, finalized statuses and catch-up cases on both pins, while the explicit retained END/loss policy in
test_spectator_session.gd guards that distinct contract. Source lib log
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Spectator receipts
db16ff837697fc608356e56fedcfaf3d774e46b34b21e1f8475f42cb74356e6a/7acfd180aa2757313ad9bace045192875e5a1a415a621457be37a641be67cfee.
Archive member SHA-256 reviewed 348bfb170f775c89b39156c8c4e4ec21e6ac1a812465b793ae4e2bd4ed823c7c, candidate
4c1fc37552bb6ad2dba3a479ac890ffd924dfd36d774d307933aaf777e3350a8.

### Decision 238

`src/sessions/player_registry.rs` · `inapplicable`

The exact archive files differ only inside the Rust test module tests. Removing that module yields the same
dependency source at both pins. The Godot/native packages link the released crate, and its 2,103
no-default-feature library tests passed against the candidate archive. Reviewed member SHA-256
a73a0a2e7ccf948b32ad07e55fe3d03bd8c2002fe55c9e8b8c0040d9ebc08a8f and candidate member SHA-256
413f7fff157486ea62bc80356eeb63a51d9c7be95dd4f0497a7e205e322fa3ca. Candidate complete build/test log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/src/sessions/player_registry.rs

### Decision 239

`src/sessions/ready_transcripts.rs` · `intentional_divergence`

The new Rust table retains provisional non-authority READY, promotes only matching reports upon an
authority/history lock and discards mismatches. The nine direct unit tests pass and the exact TLC
CoordinatedReadyDigest authority-locked configuration checked 120,516 states with no error. Godot instead uses
one authorized coordinator and requires its independently derived cut/digest to match every surviving
certificate before counting commit. A differing certificate fails the barrier, while duplicate identical
reports are idempotent. This is the distinct Godot all-survivor contract exercised by test_peer_drop_commit.gd
and the grouped history observer. Source lib log
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c; model log
ae81fd93325169037d110cea1a3cd55694cd8a075fc7dc21c5e246f7bee835a2; grouped receipt
f9d1d94c89c0e44162cc9eb7dd1a8802f600549b161d2e00c4a9645ee6a2b58c. Archive member SHA-256 reviewed absent,
candidate 621aad3988619b5f86eac3cf59ad4127b79c362efc9d81e20067594b21c135a7.

### Decision 240

`src/sessions/sync_test_session.rs` · `inapplicable`

The exact archive files differ only inside the Rust test module tests. Removing that module yields the same
dependency source at both pins. The Godot/native packages link the released crate, and its 2,103
no-default-feature library tests passed against the candidate archive. Reviewed member SHA-256
b8e16e2eab2b1d830f185689c679803d1aac9cac54ff45285edd9508da0fa18c and candidate member SHA-256
1a884a05029ae633c513c5adc339ab43899712123b74ea76923b1057ad9f05d2. Candidate complete build/test log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/src/sessions/sync_test_session.rs

### Decision 241

`src/sessions/terminal_epoch.rs` · `intentional_divergence`

The new Rust module assigns monotone terminal epochs per canonical target set and generations, bounds storage,
and separates current from one-ahead generations and bounded fallback adoption. Source module tests pass, and
the selected failover receipt observes epoch-0 PREPARE/INVENTORY refusal during an epoch-1 attempt. Godot
fixes the target roster and generation-local sequence, remembers the full identity in a bounded journal, marks
the endpoint departed and never reopens it or transfers to fallback authority. Existing
test_peer_drop_barrier.gd covers closed-operation, stale operation/era and stale donor controls, and the
comparison shows timeout with the same canonical original prefix. Source lib log
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Candidate failover receipt
805352d06bfd6119d124d8a2ce03fea55964a5392974b3449a42b256be4a2cd1. Archive member SHA-256 reviewed absent,
candidate eb4ccced13218f1a81037ddb33d51351a33449523043d35c4df5445d57d88ef2.

### Decision 242

`src/sync_layer/game_state_cell.rs` · `intentional_divergence`

The source adds data-presence queries for optional Rust cells, including normal, Loom and Kani definitions.
Godot instead publishes the snapshot tag/generation and owned payload together on successful completion. A
legitimate committed zero-byte snapshot is loadable, while overwritten, uncommitted and prior-generation
requests are refused. test_snapshot_history.gd exercises these boundaries. Both Godot pins passed the existing
suites, result hashes 5ae23872e4283f2756ca4a2aa7d1e8abddc253ce1c09eb1d559111050516fdcf,
43d5d9a4534d6d92807518fcbfce92f7ef8a40c506571b3ca4e4c3a827f6ace3. Reviewed archive member SHA-256
1dc98ec0081f59544ff88cf1881ee0e57370165adc7ea1432839f642d105013b and candidate
0367a0bc9c5f29482eb365648be4080be420a945b590e786fe1219631914b6b1.

### Decision 243

`src/sync_layer/mod.rs` · `intentional_divergence`

The source changes confirmed spectator input storage to bounded SmallVec with fallible allocation, refuses
frame-stamped cells without data, and computes a shared earliest servable input frame including disconnected
and optional reactivation tails for sparse checkpoint selection. Godot owns bounded packed bytes and expiring
snapshot leases, requires a populated retained snapshot and per-slot actual history at the exact rollback
frame, and fails closed with HISTORY_UNAVAILABLE rather than selecting a later sparse checkpoint. Its dense
rollback and shared queue floor are tested by the global-floor oracle and snapshot-policy suites. Reactivation
is explicitly excluded. The candidate library passed no-data LOAD and disconnected-tail checks. Source lib log
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c. Both 367-operation floor receipts
05b0ec17e80f590207c88bc16aae0f188836aeb28a8f7727976fd6a1a4364bef/e5de09f3f42e67deaff5eb5784b43bad544e06088a85c98dc49b7803b051730c.
Paired Godot snapshot-policy receipts
5ae23872e4283f2756ca4a2aa7d1e8abddc253ce1c09eb1d559111050516fdcf/43d5d9a4534d6d92807518fcbfce92f7ef8a40c506571b3ca4e4c3a827f6ace3.
Archive member SHA-256 reviewed c873b725dd249cf46f77492233518d531fc1af5fe8b2d5ddb618bd6f51129104, candidate
4942b70267b98bc992d1b04f5bc5113ea6aea552d89ce9a9670cacaa7e169547.

### Decision 244

`src/sync_layer/saved_states.rs` · `inapplicable`

The exact archive files differ only inside the Rust test module tests. Removing that module yields the same
dependency source at both pins. The Godot/native packages link the released crate, and its 2,103
no-default-feature library tests passed against the candidate archive. Reviewed member SHA-256
e44f4e535081db8117bb6d69a193b9057f03d59305d0f4980b1b2958ed763bf8 and candidate member SHA-256
5417b2a84c8b49b5a699d8f4ceebc3f59ce3b0100a6daf496c59bd260aa0d94a. Candidate complete build/test log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/src/sync_layer/saved_states.rs

### Decision 245

`src/telemetry.rs` · `intentional_divergence`

The added nightly violation-census feature records bounded file-and-line locations using the Rust telemetry
macro/observer lane. The Godot diagnostic contract preserves an owned bounded frame/input/checksum window and
the first divergence. Its capture schema does not depend on Rust macro locations or filesystem-backed
call-site census. Exact candidate library selection ran the new socket metric case and the diagnostic macro
cases, 8 passed and 0 failed (log SHA-256 385a7998e5236b607cfab24ed8afc70ae5a6e2e14ef3c0f6a7bed577937a7c41).
Godot policy contracts are independently asserted in tests/unit/test_peer_drop_simultaneous.gd,
test_peer_drop_capacity.gd, test_diagnostic_trace.gd, and test_peer_diagnostic_trace.gd. The focused Godot 4.3
run passed 20 cases in two fresh runs (result SHA-256
2bc916d08327f22d1ebb44f3a2f59055aaec479cd5f4e236ffab9793a9ede1b4). See docs/diagnostic-reproduction.md and
docs/peer-lifecycle.md. Reviewed member SHA-256
b754d4175495a0d94514b60f435cd88bba58134cdf468fbeb6abee54068d8735. Candidate member SHA-256
1075bf30e5fc0c2e51641861e368ec1ea6a3f7bf9ff94b38a31946f9e6301944.

### Decision 246

`src/time_sync.rs` · `inapplicable`

The exact archive files differ only inside the Rust test module sync_layer_tests. Removing that module yields
the same dependency source at both pins. The Godot/native packages link the released crate, and its 2,103
no-default-feature library tests passed against the candidate archive. Reviewed member SHA-256
c3204bb10fd70cb3ca9c536d70bd47b7fcb926578e5b055953b297f1142bdefd and candidate member SHA-256
2f1a48145033092b7fb06819ce93813ffda4f8709d4b7ea981cc1026f70f13ea. Candidate complete build/test log SHA-256
1863bd716b0fed44b83e8d21a06288eb9d00f77db894fb29d13abaf20bc7445c.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/src/time_sync.rs

### Decision 247

`tests/allocation_contract.rs` · `intentional_divergence`

The candidate extends process-global StatsAlloc probes to warmed receive and spectator host frame paths and
updates per-path ceilings. Godot's measured hot-path and snapshot-copy workloads assert canonical results and
bounded storage under the engine allocator. The independent Godot allocation-count and sustained-memory work
remains open in #43. Exact candidate Cargo 1.99.1 locked offline with default features disabled passed the
allocation contract, representative two-player smoke, and realloc contract (log SHA-256
bdac1dbcb7e578f590f4ea6fe4db9c33786edbe867ff0969fc29bbeef99aed8e). Godot make hot-path-probes completed 400
frames and 3 player-count reports with identical canonical checksum fields across both engine pins (log
SHA-256 d265b12204fcf75dd6e3a8785847be4c8029da4c2810f8620abe2b38ec5e94b0,
ea2b9aa58398431503388f74fadc002250df0a7c6c904fd5055fbe829e79c547). See
docs/experiments/session-hot-path-performance.md and docs/verification-policy.md. Reviewed member SHA-256
be65b60d036e0ba30c1d90b845c138d24f4afdb87a165f3ef5865d60d23a7851. Candidate member SHA-256
b641e8cc9f89648f9a71d42c1c07d57a22856a7e2dc1ea896514441a6981655e.

### Decision 248

`tests/common/sim_net.rs` · `intentional_divergence`

Rust deterministic simulation counts seeded duplication, direction-specific reordering, base delay and
burst-loss per link. Godot’s separately deterministic packet scheduler records scheduled and delivered
messages and fault evidence for named scenarios with explicit loss, reorder, wrap and asymmetry. No equality
of upstream RNG or telemetry counters is required. Paired actual v6 Rust/Godot comparison passed all 67
scenarios on Godot 4.3 and 4.7.2, including loss, reordering, queue wrap, checksums and lifecycle events in
the scoped profiles. Source packet profiles and Godot protocol frames are compared in their own
representations. Receipt SHA-256s 61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Archive member SHA-256 before
9f6dc3dde4a1e7380b84dbbecfe7a3bf9c9870fd235c2cbf7361f1c718a73f94, after
1e05d64e26de28401ca7100bfc259b00291cc825fe86e1774582ac9d54f940a1.

### Decision 249

`tests/common/stubs.rs` · `inapplicable`

The entire change adds derive(Debug) to Rust integration StubInput. It preserves serialization, layout and
gameplay values. Old archive member SHA-256 ee4e70ef7159e6202641f9102c9b477b82bfa9ac280093a492d65c94834e64c5
and candidate b1961935139ba1e1b2b523347c3729e13cb383b04653b0e508bfc1b500faf52c.

### Decision 250

`tests/common/test_utils.rs` · `inapplicable`

The diff is limited to the Rust harness parallel ephemeral-port test. It holds each successfully bound socket
until the last thread joins, removing its ten-millisecond heuristic. No transport session code or
deterministic fixture inputs changed. Old archive member SHA-256
a168465d003846ae1aedbf7da6bf17e5bbb8c5f8aba57b057e0d7317930e5a08 and candidate
ca178580ad24c6545f79b599d2cf20049b276d044b35e96d1c1221c8bee83b00.

### Decision 251

`tests/config.rs` · `inapplicable`

The edit checks Rust Debug derives for the four configuration struct type names. Godot configuration
validation does not expose those Rust formatting contracts. Old archive member SHA-256
1ecf913e61c1d9fed09bb6176320e5d69241f66dd70579f099b0f7eec7ab94a4 and candidate
9874a1e637e25925bddfe2594a8adabf718229a5761388833871647fdfd2fdf4.

### Decision 252

`tests/godot-emscripten/Cargo.lock` · `inapplicable`

The lock refreshes the upstream probe workspace dependency resolutions and adds the test-only replay-fixture
crate. The package uses the independent experiments/gdextension/Cargo.lock SHA-256
a17d825fa8cdec230ee96851d88792d452940bf1f086dd02cf7a26e69589a2b0 and the checked Emscripten build script. The
locked release Emscripten feature tree SHA-256
bac911b863e2889b606576df77ccbe40a05c010e06562a5413ac9713c23ea5a3 excludes the fixture crate, wasm-bindgen,
Tokio, hot-join, and test-probes. Local package audit SHA-256
211aad928fc6bfe9ecd7bcccbefb88c9eb6855e7f0ec2cb5494f5635c79a8a6f records the verified candidate native and Web
ZIPs plus actual Chromium, Firefox, and Playwright WebKit exports on both Godot pins. Compared archive member
SHA-256 values are 5f1e5dd33890ccb6facd47a6b45ee7795e5e282c59d89fa02c94ac001ebde593 and
17b56cf7b43ccb447f6fba07127e1fb50ba089c04c7121bc2afec2cc6bff047a.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/godot-emscripten/Cargo.lock

### Decision 253

`tests/godot-emscripten/Cargo.toml` · `inapplicable`

The hunk changes the standalone upstream test crate to link hot-join, test-probes, and replay-fixture. Those
are workbench dependencies, outside the supported fixed-roster package and separately tracked hot join. The
locked release Emscripten feature tree SHA-256
bac911b863e2889b606576df77ccbe40a05c010e06562a5413ac9713c23ea5a3 excludes the fixture crate, wasm-bindgen,
Tokio, hot-join, and test-probes. The overlapping runtime evidence in the source probe remains under separate
source-file review. Compared archive member SHA-256 values are
824c5f327eb6f459d0c674d1570df0d462e67aafd45755eefe635e748c8e1265 and
d19d6c958301ed266dca2923fa502babc5ed97fb18452220d02eb6f8a9594c7f.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/godot-emscripten/Cargo.toml

### Decision 254

`tests/godot-emscripten/browser.spec.mjs` · `intentional_divergence`

Exact candidate source CI 46046809665, job 140667989987, ran the console policy and both Godot/Emscripten
exports: 3 passed. The changed assertions require certified removal/hot-join/epoch import and 4,096 frames,
8,192 requests and exact source replay digests in both modes. The exact candidate WASI job 140667990454
independently printed those frame/request totals and both expected hashes. The separate Godot project
rehearsal 46072793492 produced 12 digest-verified platform cells, 32 canonical 40-row matches and 32
restore/encoding controls. Its contract selects the source archive and uses fixed-roster default-feature-free
packages. It does not enable the upstream test-only hooks or certified membership/epoch import. Cross-target
source replay is a separate signature and format. Reviewed archive member SHA-256
18783c520e0c2f5c86f41cf4df062fd0ae81a88cffbd4491560247de7d3c0078 and candidate
f27e9fd335a0c28a73cafd34cfd0636b9bfc021b506bc3f12c4a74ccc157ff51.

### Decision 255

`tests/godot-emscripten/godot/main.gd` · `inapplicable`

The hunk adds five replay failure sentinel fields to the private upstream probe dictionary. The shipped Godot
and native runtime do not consume that dictionary schema. The independent exported fixture rejects missing
libraries and mistakes in restore and input encoding at their named checkpoints. Local package audit SHA-256
211aad928fc6bfe9ecd7bcccbefb88c9eb6855e7f0ec2cb5494f5635c79a8a6f records the verified candidate native and Web
ZIPs plus actual Chromium, Firefox, and Playwright WebKit exports on both Godot pins. The separately changed
replay behavior remains under source-file review. Compared archive member SHA-256 values are
097688d5c19d385d63d4f3d522ddaeb6b10bd3e0cf7a9fd2d5b8575d740215b8 and
29dbddb47f84213506d28710d4cc48965a99fbffc81b9e2ea05d30fb6f8a50dd.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/godot-emscripten/godot/main.gd

### Decision 256

`tests/godot-emscripten/package-lock.json` · `inapplicable`

Regenerates versions and integrity records for the upstream probe Playwright upgrade from 1.63.0 to 1.65.1.
The Godot qualification uses Playwright 1.64.1 through docs/reference/pins.json and
.github/workflows/gdextension-experiment.yml. Local package audit SHA-256
211aad928fc6bfe9ecd7bcccbefb88c9eb6855e7f0ec2cb5494f5635c79a8a6f records the verified candidate native and Web
ZIPs plus actual Chromium, Firefox, and Playwright WebKit exports on both Godot pins. Compared archive member
SHA-256 values are ae4549e1eb0b407a348942d30fe1273ee694b055b6f44b949f5586aa42622bb8 and
bd6acd5da9cfac8db3038aa2bd2103e0d96d05411c996acef870de350a67fb6a.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/godot-emscripten/package-lock.json

### Decision 257

`tests/godot-emscripten/package.json` · `inapplicable`

Raises Playwright only for the upstream Chromium probe. The production extension build neither resolves nor
installs this package. The Godot qualification uses Playwright 1.64.1 through docs/reference/pins.json and
.github/workflows/gdextension-experiment.yml. Actual candidate browser interop demonstrates the independent
supported test toolchain. Local package audit SHA-256
211aad928fc6bfe9ecd7bcccbefb88c9eb6855e7f0ec2cb5494f5635c79a8a6f records the verified candidate native and Web
ZIPs plus actual Chromium, Firefox, and Playwright WebKit exports on both Godot pins. Compared archive member
SHA-256 values are 6a36ad1f6aa9e16bda9e3e0235e5cd596c9920f9c51af91d59c80a217cf2d5c2 and
6c448a7e9a3184436dee033bdb4f83387692ffbaf33cf55ab2e645c1bc6d2173.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/godot-emscripten/package.json

### Decision 258

`tests/godot-emscripten/run.sh` · `inapplicable`

Adds a Chromium-only install retry when Playwright dependency installation fails in the upstream probe. The
Godot workflow owns apt mirror preparation and bounded install-deps retries through
scripts/reference/retry_apt_fetch.sh, then runs fresh exports on each installed browser. Local package audit
SHA-256 211aad928fc6bfe9ecd7bcccbefb88c9eb6855e7f0ec2cb5494f5635c79a8a6f records the verified candidate native
and Web ZIPs plus actual Chromium, Firefox, and Playwright WebKit exports on both Godot pins. See
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492 for separately
scoped hosted jobs. Compared archive member SHA-256 values are
a64c5a25d1a44f3d3a1f38dd6920568e48b5c9509198cc252d2050d96040216f and
0baccd20a120396975847861e95171271747ca833839e2568b6533e62ca0203f.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/godot-emscripten/run.sh

### Decision 259

`tests/godot-emscripten/src/lib.rs` · `intentional_divergence`

Exact candidate source CI 46046809665, job 140667989987, ran the console policy and both Godot/Emscripten
exports: 3 passed. The Rust engine probe constructs the source-only certified operation, activator and replay
result which the two exported browser cases assert. The separate Godot project rehearsal 46072793492 produced
12 digest-verified platform cells, 32 canonical 40-row matches and 32 restore/encoding controls. Its contract
selects the source archive and uses fixed-roster default-feature-free packages. It does not enable the
upstream test-only hooks or certified membership/epoch import. Cross-target source replay is a separate
signature and format. Reviewed archive member SHA-256
b70d9b4b67688e92645355aec975bf5285168651107e009d9748e7baed49bef8 and candidate
c248cea94f817edee7dfbf1a79641dce4055d4a20a9c8a90ecea250643f85ea3.

### Decision 260

`tests/network-peer/Cargo.toml` · `inapplicable`

Changes feature unification for the upstream test-only network-peer package and keeps its hot-join feature
alias. The native package builds its own reference-peer binary with the peer feature and a dependency on the
exact Fortress production archive. That supported fixed-roster binary has no network-peer or hot-join
dependency. Local package audit SHA-256 211aad928fc6bfe9ecd7bcccbefb88c9eb6855e7f0ec2cb5494f5635c79a8a6f
records the verified candidate native and Web ZIPs plus actual Chromium, Firefox, and Playwright WebKit
exports on both Godot pins. Compared archive member SHA-256 values are
f2c81ca301a7b7093fa26d9d363e9f825e9e636ceaabac715605786d84f974f7 and
e6ea5a03523a73a17bdced2e24e331281e5c782635e7e280440e7e5bbfebee8b.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/network-peer/Cargo.toml

### Decision 261

`tests/network-peer/src/main.rs` · `intentional_divergence`

The changes make the upstream test peer count join events and accept a configurable disconnect timeout. The
Godot scope excludes reserved-slot hot join in docs/supported.md. Its selected-source P2P harness plumbs
explicit per-schedule timeout_us through scripts/oracle/p2p_lifecycle_corpus.py and
scripts/oracle/rust/src/bin/p2p.rs, and compares interruption, recovery, and disconnect from both
implementations. Exact v6 lifecycle-bearing receipts on Godot 4.3 and 4.7.2 have SHA-256
61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366 and
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. The standalone Godot interoperability peer
retains its separate CLI. Compared archive member SHA-256 values are
7e688d50c499a5023c58eca7da2be4651837d0002ff1c6055c392bae9c7fb325 and
8a1bc0832437dd2f2aeb8ece02669111feea9e9ea8401745877fb6443c97a6d6.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/network-peer/src/main.rs

### Decision 262

`tests/network/multi_process.rs` · `intentional_divergence`

The source child-process UDP nightly lane introduces ten seconds of host-stall tolerance only for loss-bearing
nightly rows and leaves production timeout and PR smoke rows intact. Godot package and browser process
qualification has separately bounded real connections, while fixed virtual time covers actual endpoint expiry.
Exact candidate CI Network Tests 46046809651 passed the Linux, macOS, Windows and Docker jobs. The Linux smoke
log reported 62 passed and 216 skipped. Paired actual v6 Rust/Godot comparison passed all 67 scenarios on
Godot 4.3 and 4.7.2, including loss, reordering, queue wrap, checksums and lifecycle events in the scoped
profiles. Source packet profiles and Godot protocol frames are compared in their own representations. Receipt
SHA-256s 61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Archive member SHA-256 before
4dcdde813d860183ce9022121415fe5122cfb184059f45b45c7a7181254093e5, after
e2aa4700f9a8f8cecf1e953c77b9a3d2afebd6182038d8e6febe03c31da59978.

### Decision 263

`tests/network/resilience.rs` · `intentional_divergence`

The added Rust 250ms/15% diagnostic measures prospective ACK-limited confirmation exposure and documents the
policy tradeoff rather than choosing an always-ACK cap. The Godot product uses separately specified endpoint
confirmation folding and a distinct packet timing envelope, and does not claim this experiment’s terminal-tail
guarantee. Existing one-way partition and profile limits remain scoped. Paired actual v6 Rust/Godot comparison
passed all 67 scenarios on Godot 4.3 and 4.7.2, including loss, reordering, queue wrap, checksums and
lifecycle events in the scoped profiles. Source packet profiles and Godot protocol frames are compared in
their own representations. Receipt SHA-256s 61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366,
38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd. Archive member SHA-256 before
b4c18b4a008fc95cb26aa17d04ea37e2e77ffa160d6c4a8b21abe7a792b74838, after
b13b12e3a2ddc9c4930aacb7bafae948d634d15c7ced6b7fbd2ba6c4abc6b0c1.

### Decision 264

`tests/network/soak.rs` · `inapplicable`

Only a Rust allocator measurement test is relocated into an isolated stats_alloc_contract process; the
existing memory calculation is untouched. This protects the Rust allocator’s realloc-counter semantics and is
independently audited in the new test file. It does not change port runtime, fault policy or user-facing
performance coverage. Archive member SHA-256 before
a5a11f0f8402ff3fffcd9c34312bfec2aae9576d197efa604f8855a360886a38, after
f714d9481a0c105142b47c03138a3ff721a61c2f036d7caf8f9b2b68b81d7695.

### Decision 265

`tests/replay-fixture/Cargo.toml` · `inapplicable`

This workspace manifest selects the upstream test-only replay fixture with opt-in capture and hot-join test
features. The fixed-roster Godot package and replay oracle depend on the production library, with their own
test fixtures and Cargo configuration. They neither distribute nor link the upstream fixture package.
Candidate fortress-replay-fixture native library tests with hot-join enabled passed 7/7, log SHA-256
1e68604b6a27f11581e5d444eacfc4cebb82d5e893438694920b6a97b1c8b4ab. The member is absent from the historical
archive. Candidate archive member SHA-256 7b2594bcf56a90aea52c07934c258ae2900b32a559d1ac4e66aff104ad1cde84.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/replay-fixture/Cargo.toml

### Decision 266

`tests/replay-fixture/fixtures/portable-replay.bin` · `intentional_divergence`

The 4096-frame upstream binary is encoded in the generic Rust Replay format; its native fixture tests consume
the exact archive member, validate recorded state and request digests, and reject a mutated recorded checksum.
Godot uses separate FRRP versioned files, independently generated input histories, and native callback/expert
playback checks. The paired receipts do not import this binary or claim compatibility with its layout.
Candidate fortress-replay-fixture native library tests with hot-join enabled passed 7/7, log SHA-256
1e68604b6a27f11581e5d444eacfc4cebb82d5e893438694920b6a97b1c8b4ab. Verified paired replay receipt SHA-256
values: 4.3 candidate ef58d9c9eb8a50b8576a60db0cb4f5a2a49b0c55adb6d62afef9f9fc6b5f29d7, 4.3 historical
c0bcf1ae4dc2dfabb633af5f5dfc4d4324fa77bc9e8fde224f8a8f9ec7e0756b, 4.7.2 candidate
62a9a153a8fb3d17f086c4ed7523e73b72b8d983cd2eef49d8b5294ae3cb68f6, 4.7.2 historical
0447e717a67380975c8bc040be21d3490c8bf115d24d2e66bf3b5de401b812e4. The member is absent from the historical
archive. Candidate archive member SHA-256 39ce558f61ed079151a53a4ac60f202adf4585ed185d79259cc95e5a840df1ba.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/replay-fixture/fixtures/portable-replay.bin

### Decision 267

`tests/replay-fixture/src/bin/wasip1-replay-probe.rs` · `inapplicable`

This upstream test binary targets wasm32-wasip1 under wasmtime; it checks the captured Rust replay and
source-specific machine-width, compression and wire digests there. The supported Godot runtime matrix in
docs/supported.md covers Linux native and exported Godot Web. A native fixture pass does not qualify WASI or
stand in for a WASI invocation. Candidate fortress-replay-fixture native library tests with hot-join enabled
passed 7/7, log SHA-256 1e68604b6a27f11581e5d444eacfc4cebb82d5e893438694920b6a97b1c8b4ab. The member is absent
from the historical archive. Candidate archive member SHA-256
d3023918234c2478b851de1eb173130d5c5081d9a144fe50134f17daae09cbaa.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/replay-fixture/src/bin/wasip1-replay-probe.rs

### Decision 268

`tests/replay-fixture/src/lib.rs` · `inapplicable`

Upstream test-support code embeds its 4096-frame Rust Replay artifact and shares machine-width, compression,
wire and playback assertions across its own test targets. The Godot addon uses its own FRRP decoder,
independent original-input oracle and exported-Godot evidence; it does not link the fixture library. The
fixture above was executed on the native Linux host. Browser, Emscripten and WASI results are not inferred
from that execution. Candidate fortress-replay-fixture native library tests with hot-join enabled passed 7/7,
log SHA-256 1e68604b6a27f11581e5d444eacfc4cebb82d5e893438694920b6a97b1c8b4ab. The member is absent from the
historical archive. Candidate archive member SHA-256
7d90f599503315e6e42ec787a1ee8ae0194d43d2efbb0e6d10ac45217f30b16d.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/replay-fixture/src/lib.rs

### Decision 269

`tests/representative_perf.rs` · `intentional_divergence`

The new Rust test target measures a real in-memory Rust mesh with configurable snapshot size, delay,
prediction and load. Godot retains its own steady-frame, rollback, codec, driver and owned snapshot
measurements on both pinned engines with canonical checksums. The candidate release-only tier ledger is an
independent performance workload. Exact candidate Cargo 1.99.1 locked offline with default features disabled
passed the allocation contract, representative two-player smoke, and realloc contract (log SHA-256
bdac1dbcb7e578f590f4ea6fe4db9c33786edbe867ff0969fc29bbeef99aed8e). Godot make hot-path-probes completed 400
frames and 3 player-count reports with identical canonical checksum fields across both engine pins (log
SHA-256 d265b12204fcf75dd6e3a8785847be4c8029da4c2810f8620abe2b38ec5e94b0,
ea2b9aa58398431503388f74fadc002250df0a7c6c904fd5055fbe829e79c547). The representative tier ledger stayed
ignored at its declared release-only boundary. See docs/experiments/session-hot-path-performance.md and #43.
Reviewed member SHA-256 absent. Candidate member SHA-256
76682a44162d481697be03ed4e6de6284e0b11c206be7cb0ef5f2dbb38eb3936.

### Decision 270

`tests/sessions.rs` · `inapplicable`

The entire archive-member diff adds Rust integration-test module registration for misuse and replay_recording.
It changes no library or binding API. The added modules ran against the candidate archive with
replay_recording 6/6 (log SHA-256 51f62d77ddfce57f5e5c8e4b98b2ab716c3c7142db127aa40ed7bde5a3c59c63) and misuse
3/3 (log SHA-256 aa529886df8a6b371da29729fe84e4e5f3646788c80e86679baab0a5dcd6b7fe). The Godot test runner uses
its own suite registration and invokes the paired replay launcher separately. Historical archive member
SHA-256 a07b5bef083d0764edb33ffe7282847c47531c501db3328988a3bcd5419d1d50. Candidate archive member SHA-256
fcc25e570fb6768ff4245e4374a6a53dc9f828858459956319006e0687596bd9.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/sessions.rs

### Decision 271

`tests/sessions/desync_harvest.rs` · `intentional_divergence`

The source fixture seeds protocol RNG, advances the injected TestClock after every poll round and requires
retrieval of each confirmed row. Both changed reorder-history source tests pass. Godot schedules protocol time
and tokens explicitly and compares canonical states and complete confirmed prefixes. The archive-selected
mesh_3_asymmetric_recovery_wrap, mesh_4_reorder and checksums_repair scenarios passed twice on both pins,
using the Godot observer’s schedule and separate raw transport envelopes. This binds the common
determinism/canonical-prefix requirement with independent Rust and GDScript fixture implementations. Source
focused integration log 60c0a752c3c4b2dc60c13289bdf380a37d49a1926a74dbc08ba98aa8edf574e0; P2P receipts
61403c890c70b24259e5a7c41f4185585783f3681b433cf7fa371147b67a4366/38fa7448162f742385dd6ad343adb753dd51f993f1d6bbbad9a6df16e59ac9bd.
Archive member SHA-256 reviewed 3637043db7235a28bea19a038b60c10cabc78060fff14734550e51966fd48a8e, candidate
6eb32d2dc0b9a5c879e5083d4b4db7e9448b9cf4be6b8cb018e9247e5a0b9982.

### Decision 272

`tests/sessions/hot_join.rs` · `intentional_divergence`

The source tests bound serve retry/backoff, refuse oversized snapshots without halting the host, stop
witnessless automatic timeout without rejoin, and preserve the explicit removal/rejoin control. Candidate
upstream aarch64-QEMU and i686 CI passed those cases. The Godot fixed roster neither opens a state-transfer
serve nor reactivates a retired player. Its existing last-survivor rule without rejoin is documented in
docs/peer-lifecycle.md, with a complete retained-history continuation witness in test_peer_drop_history.gd.
Native package qualification uses fixed-roster rooms and does not extend the hot-join support scope. #50
tracks reactivation. Source CI
https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046809665. Archive member SHA-256
reviewed 1873dd3bcbed5db0f44bcc1865a32105d11bd9c016916760d25a2c81caab8796, candidate
dd8fa94aef9d27bceb52650989f556800ab4369f6e465f0baaae51d0380f89bf.

### Decision 273

`tests/sessions/macro_tests.rs` · `inapplicable`

The added tests exercise the Rust try_handle_requests macro’s closure error propagation. Godot calls its own
driver methods and does not invoke the Rust macro. The corresponding callback stop contract is exercised by
tests/unit/test_driver.gd and documented for native in docs/native-backend-migration.md. Archive member
SHA-256 reviewed ba8d5b9ec2a222bc37da61d4ec0c426684b8c23329a377c477174ec6ddda5222, candidate
61f7433de05b779b011ef91b17224c7a8bf3a90779739f2566f8ca3697474c39.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/sessions/macro_tests.rs

### Decision 274

`tests/sessions/misuse.rs` · `intentional_divergence`

The new source fixture requires visible failure for missing saved state, a Serde checksum error, and omitted
local input. All three source test cases pass. Godot’s analogous ownership contract refuses an
unavailable/expired snapshot before loading, rejects missing samples before advance and requires a successful
save with a 16-byte game checksum. GDScript does not serialize the application state through Rust Serde.
Targeted session and snapshot tests include missing-local-input and width/callback failure, with paired
snapshot policy receipts
5ae23872e4283f2756ca4a2aa7d1e8abddc253ce1c09eb1d559111050516fdcf/43d5d9a4534d6d92807518fcbfce92f7ef8a40c506571b3ca4e4c3a827f6ace3.
Source focused integration log 60c0a752c3c4b2dc60c13289bdf380a37d49a1926a74dbc08ba98aa8edf574e0. Archive
member SHA-256 reviewed absent, candidate 743550fe97e92bdcaa2a73d352a82d2d7b3596d044a769ba4134bf0a55f1b86b.

### Decision 275

`tests/sessions/p2p.rs` · `intentional_divergence`

The only changes assert that an added Rust spectator endpoint does not count as a player and startup remains
Synchronizing for the two- and four-player configurations. Both exact source tests pass. Godot spectator
streams attach to independent publisher/viewer APIs outside a P2P player mesh; adding a spectator cannot be
represented as adding a player to that roster. Candidate selected spectator comparison checks complete
roster/status traces on both engine pins. Source focused integration log
60c0a752c3c4b2dc60c13289bdf380a37d49a1926a74dbc08ba98aa8edf574e0; paired spectator receipts
db16ff837697fc608356e56fedcfaf3d774e46b34b21e1f8475f42cb74356e6a/7acfd180aa2757313ad9bace045192875e5a1a415a621457be37a641be67cfee.
Archive member SHA-256 reviewed ff072bff09869e6955be962a2f255eedd7225bd7bf072e6c7591f9efc4614a66, candidate
a108c68f5ddc86f42cd39b078a97507b39aa86804a62de34b163da42230f9517.

### Decision 276

`tests/sessions/peer_drop.rs` · `intentional_divergence`

Changes exercise explicit Goodbye, witnessless timeouts, delayed confirmations in double failure, retained
canonical safety and optional hot-join rearm assumptions. The three named candidate Goodbye/timeout tests and
the four- and five-peer changed double-failure fixture assertions passed. Godot keeps confirmed-history and
timeout controls, including grouped retained receipt protection and fail-closed missing donor, participant and
corrupt certificate cases, separately from Rust event spelling and host reactivation. The source separates
explicit Goodbye, which certifies the receiver immediately, from witnessless automatic timeout, which emits
neither PeerDropped nor Disconnected, leaves confirmation unchanged, and refuses further advance in both
two-endpoint and multi-handle one-remote cases. The Godot _live_survivors()==0 exception expressly documented
in docs/peer-lifecycle.md#the-coordinated-drop still allows a one-member timeout freeze after verifying the
retained local history. test_peer_drop_history.gd::last_survivor_receipts plays through physical silence using
two encoded peers, certifies cut 5 and cut 8 with three extra actual receipts, advances another 12 turns and
independently checks canonical states, replay bytes and disconnected status. test_peer_drop_multi_slot.gd
verifies both covered grouped continuation and refusal of incomplete grouped history. This is a deliberate
legacy limitation. Matching the newer witness rule and qualification of symmetric two-endpoint partitions
remain in #48. Fresh paired Godot results SHA-256
ab557a534dfe9b5e2172820665dba8d6684e5f0f959952c393cf1267af5022e9/36b5b829789fbf1f734cedf34a8711e8a299eff106551d0dd83ade85ca1d8c02.
Source focused integration log 60c0a752c3c4b2dc60c13289bdf380a37d49a1926a74dbc08ba98aa8edf574e0; candidate
paired grouped receipt f9d1d94c89c0e44162cc9eb7dd1a8802f600549b161d2e00c4a9645ee6a2b58c; candidate coordinator
failover receipt 805352d06bfd6119d124d8a2ce03fea55964a5392974b3449a42b256be4a2cd1. Archive member SHA-256
reviewed 1220b4db8fe8c61cd1629732f29680a79373f528d86adf95869ce474ed1e377e, candidate
093863eb673b6719d6dc5be82a9e3ddfd573a80741d30e960f4a1139554ca27a.

### Decision 277

`tests/sessions/replay_recording.rs` · `ported`

The candidate source suite covers corrected replay, live checksum consistency during a correction burst, the
missing-local-input contrast, dense and sparse recovery, prediction-matching recovery, and withholding without
invented input. Candidate sessions::replay_recording passed 6/6, log SHA-256
51f62d77ddfce57f5e5c8e4b98b2ab716c3c7142db127aa40ed7bde5a3c59c63. The paired Godot/Rust replay observations
independently check changing and neutral histories, exact correction and repeated SAVE, 257 original rows at
an unchanged boundary, withheld exports that stop at 256/255, and canonical playback. The source suite
directly verifies its Rust-only save policies and error behavior. Verified paired replay receipt SHA-256
values: 4.3 candidate ef58d9c9eb8a50b8576a60db0cb4f5a2a49b0c55adb6d62afef9f9fc6b5f29d7, 4.3 historical
c0bcf1ae4dc2dfabb633af5f5dfc4d4324fa77bc9e8fde224f8a8f9ec7e0756b, 4.7.2 candidate
62a9a153a8fb3d17f086c4ed7523e73b72b8d983cd2eef49d8b5294ae3cb68f6, 4.7.2 historical
0447e717a67380975c8bc040be21d3490c8bf115d24d2e66bf3b5de401b812e4. The member is absent from the historical
archive. Candidate archive member SHA-256 c061fe1d4f0778bc2919fef44ae314bbcaf64ed2070c84847332bb3f9bbb9f2e.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/sessions/replay_recording.rs

### Decision 278

`tests/sessions/session_trait.rs` · `inapplicable`

The only change gives an existing nonempty-request assertion explicit failure text. That Rust Session trait
fixture has no Godot API obligation. Old archive member SHA-256
2042fe135df9465da371b2798c045a784de400df0ae52e994648782cfb9e7ffa and candidate
b72fb59c02804076f251c9d256d5d4741014d379465d4867aa0b3c30e330f22d.

### Decision 279

`tests/sessions/spectator.rs` · `inapplicable`

The only change adds failure text to an existing nonempty-requests assertion. The candidate formal and full
spectator adapter runs separately passed on both Godot pins. Old archive member SHA-256
d0d16b8ff26446eb40fc64901d681d8904bc5af4de461b84957adc9fed272d1d and candidate
accb4938c67f5a37e818aacdd038f03cb3f0d0a4e49221107e84fdcd17a10b24.

### Decision 280

`tests/simulation.rs` · `inapplicable`

The complete member diff registers the differential, pacing and partition modules in the upstream test runner.
This changes no library API. Targeted tests reached each new module; Godot registers its own suites and source
adapters. Candidate source tests:
archive-sim-differential-save_delay_and_drive_order_matrix_matches_nominal_confirmed_history.log (1 passed,
SHA-256 8d9f95554bdbeb105886e4e3a4153332ad790c535472c513175033a8e199a919); archive-sim-pacing.log (5 passed,
SHA-256 a8052ddb86d3d95c9cc8d04d63afa13ea2a9b363fe561d7014f6fe233961d782);
archive-sim-partition-slow_peer_within_timeout_is_not_expelled_and_keeps_one_history.log (1 passed, SHA-256
596151b70321218f034f7caed16aba3c363df5560e4e3ec1824ad925e66169b3);
archive-sim-partition-sweep_schedules_materialize_declared_fault_premises.log (1 passed, SHA-256
0cc832f2f2fd51540f36b764acad67608dd03a613dd7b5ee010e52779a644f81). Historical archive member SHA-256
714d0b4c1874d0d73507cb8f847c0c13a646f1a14de16617b77f91273e1e4491. Candidate archive member SHA-256
afb9902d03fb28b84fd00fffef37113b8ca1e11bcb69ac5b0e2b7d501b1aea51.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation.rs

### Decision 281

`tests/simulation/baseline_sweep.rs` · `intentional_divergence`

The source cost sweep now retains all oracle failures and applies one-sided stall and confirmation-lag
thresholds against its native cost ledger. The Godot oracle uses a separate reviewed P2P workload inventory
and does not adopt the Rust cost limits. Candidate source tests: archive-sim-sweep.log (1 passed, SHA-256
1046d548ed66eacd66f33e30423243f28d58584f6d23d37976ce97666833a32b). Historical archive member SHA-256
f18971c34448a02c34b4d22c8b15e8a3ea3d73a8b29ca4dfc093784408d427ed. Candidate archive member SHA-256
e635d55200c1f9e3fef1065aac857d7d341bacf1075cc7386e2a06fe5fb66811.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation/baseline_sweep.rs

### Decision 282

`tests/simulation/census.rs` · `intentional_divergence`

Candidate seed 0xCE45_0030 requests two explicit graceful removals after staggered links, then certifies both
drops and resumes. Its retained-ring test permits a later diagnostic sample while requiring the bounded
capacity refusal. Godot's automatic timeout and open-certificate participant-loss policy remains separately
visible: the five-endpoint simultaneous departure test requires no partial commit and participant_lost on all
three survivors. Its capacity tests preserve retained history and refuse unprovable cuts. The Rust
explicit-removal schedule and hot-join helper are different profiles. The local exact candidate simulation
selection ran 37 tests with 0 failures (log SHA-256
af8c83c5146350a1166d2d6bac6fe0396b5f1e44c2f5c3cce57cb6ec0ddc02a0). Godot policy contracts are independently
asserted in tests/unit/test_peer_drop_simultaneous.gd, test_peer_drop_capacity.gd, test_diagnostic_trace.gd,
and test_peer_diagnostic_trace.gd. The focused Godot 4.3 run passed 20 cases in two fresh runs (result SHA-256
2bc916d08327f22d1ebb44f3a2f59055aaec479cd5f4e236ffab9793a9ede1b4). See docs/peer-lifecycle.md and
docs/supported.md. Reviewed member SHA-256 44c2d0c1225559f0789d686fc04b68296a3647999c4d85e6584e44076ca8c7b8.
Candidate member SHA-256 64448898b2687efe44d7e489b890b6d6a580d9248c32ab3877c97a4ad0e368cc.

### Decision 283

`tests/simulation/corpus/002-mixed-transport-quorum.json` · `intentional_divergence`

The exact upstream four-peer 1000-step fault schedule exercises reliable retransmission and unreliable loss,
checks both classes on distinct links, and reproduces its trace hash and per-peer confirmed frames. The Godot
network differential in docs/oracle-p2p.md uses its own explicit scenario/transport contracts. This JSON is an
upstream simulation schedule. It is outside Godot FRRP playback and does not qualify actual WebRTC or relay
behavior. Candidate case checked_in_mixed_transport_schedule_replays_with_both_transport_classes passed in the
11-test corpus selection. Log SHA-256 b24e8aca88753598e7cf4d40c5824e162aad6f5d92ec454124b54fb17da569d1. The
member is absent from the historical archive. Candidate archive member SHA-256
be2ea176aaa42e080fb431ae05c1cd212128312c8fdb6deb3ab259b0a2a26ef9.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation/corpus/002-mixed-transport-quorum.json

### Decision 284

`tests/simulation/corpus/003-extended-ring-recycling.json` · `intentional_divergence`

The exact upstream four-peer 16384-step fault schedule exercises 85 events, multiple ring recycles, mixed
transport, stalls and rollback. It reproduces its complete trace hash and per-peer confirmed frames. The Godot
fixed-roster differential uses its own explicit stress/profile inventory in docs/oracle-p2p.md. The separate
257-row gameplay replay tests qualify their original input and state histories. They do not claim a port of
this simulation schedule. Candidate case
checked_in_extended_ring_schedule_recycles_rings_and_replays_identically passed in the 11-test corpus
selection. Log SHA-256 b24e8aca88753598e7cf4d40c5824e162aad6f5d92ec454124b54fb17da569d1. The member is absent
from the historical archive. Candidate archive member SHA-256
f8c3ff2a19448f9e665c727107c635be8096b4354d6211b505717639c4d24497.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation/corpus/003-extended-ring-recycling.json

### Decision 285

`tests/simulation/corpus_replay.rs` · `intentional_divergence`

Upstream simulation schedule replay and promotion validation are separate from gameplay recording/playback.
The exact candidate selection executes deterministic mixed-transport and extended ring schedules, checks
per-peer confirmed prefixes and identical repeated trace hashes, and runs promotion/discovery tests. There
were 11 passing tests and one environment-dependent promotion helper ignored, log SHA-256
b24e8aca88753598e7cf4d40c5824e162aad6f5d92ec454124b54fb17da569d1. The feature-enabled generated hot-join
fallback test also passed, log SHA-256 9a898a931b39347f870fbbc98b241561983c4a574e909b1d83d9886753a1f1cc. The
Godot repository uses its own fixed-roster network scenarios and replay evidence. It does not import the Rust
simulation/promotion harness or enable online hot-join. Historical archive member SHA-256
71e29ba9a5918b047aaec7e2a4b74e3b55fc7eb354794789a178b12376b735c6. Candidate archive member SHA-256
18193b64777baddb3666fc6ca0f50c1f1daa64b14f72ccfa8d796a1022e4538f.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation/corpus_replay.rs

### Decision 286

`tests/simulation/differential.rs` · `intentional_divergence`

The source reference independently computes nominal StateStub history and selected membership/spectator
histories. Targeted candidate tests cover save modes and drive order, queue capacity, saved-state ring wrap
and runtime input delay increase. The Godot reference owns separate packed-byte state and fixed-roster bounds.
No full source differential run, product hot-join port or platform parity is asserted. Candidate source tests:
archive-sim-differential-input_queue_capacity_boundaries_match_nominal_history.log (1 passed, SHA-256
454373060a883f6a0fe5342c63cab41f7ac201348b15375be84cb673289e3b24);
archive-sim-differential-runtime_delay_increase_matrix_matches_controls_and_nominal_history.log (1 passed,
SHA-256 f5170e50ace4b17abb4f825423421dffb25e7d97c7327a12f57bdd3a104d3973);
archive-sim-differential-save_delay_and_drive_order_matrix_matches_nominal_confirmed_history.log (1 passed,
SHA-256 8d9f95554bdbeb105886e4e3a4153332ad790c535472c513175033a8e199a919);
archive-sim-differential-saved_state_ring_wrap_with_minimal_prediction_window_matches_nominal_history.log (1
passed, SHA-256 75e1251b5417670c724c16487c0ae99e1ae2df2adba217da9764b2d45baf1aa5). Both candidate launch
receipts passed, SHA-256 4.3 3b90016fda5e0d644ba186470dc1f72f85b043069c8bdafa01f60906c85719e0, 4.7.2
ee84241df4f49537c08e7ef5fc0e4da3b59c47977f122f997a7d113239e5e513. Both candidate queue_launch receipts passed,
SHA-256 4.3 1df6186f3ce6d31a33b90baeaaa2b973ff3eca55ff59c128cf6c8131d2999241, 4.7.2
83d4226b774f852c953b7ab415208dd612ab6eee7a2b52d32e96885926aee828. The member is absent from the historical
archive. Candidate archive member SHA-256 6d722ff70fe1e5c5ebc46539e510dd38249a3c4f6f9301474933a725ae3450e2.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation/differential.rs

### Decision 287

`tests/simulation/fleet.rs` · `intentional_divergence`

The Rust fixed and nightly fleet adds live graceful-target recovery, long suspension under extended timeout,
architecture trace digests, PCT interleavings and rare small-ring states. Godot uses fixed archive-bound
schedules with actual request/packet comparison and deliberate support boundaries. Its candidate grouped donor
receipt preserves exposed rows and rejects unavailable donor history; Rust hot join and the randomized nightly
fleet remain separate profiles. The local exact candidate simulation selection ran 37 tests with 0 failures
(log SHA-256 af8c83c5146350a1166d2d6bac6fe0396b5f1e44c2f5c3cce57cb6ec0ddc02a0). Both exact candidate Godot P2P
receipts for Godot 4.3 and 4.7.2 passed all 67 scenarios. See docs/reference/p2p-profiles.md and
docs/oracle-p2p.md for the committed supported profiles and differing transport scope. Reviewed member SHA-256
df564082d66d8ba38002be36372d88bce10b4eaf3ebbb90c16a28b6ac0d79e2d. Candidate member SHA-256
96532f138450d6495a1fa1fdefe32647cfacaf1f735456d6f042f2f778ccb0fe.

### Decision 288

`tests/simulation/harness/artifact.rs` · `intentional_divergence`

Source test failure artifacts advance to schema 9 for deterministic peer interleaving. The tested source
round-trip restores the replay options and reproduces the trace. Godot binds its own scenario, trace and tool
receipts. The Rust diagnostic artifact is separate from product recording and wire formats. Candidate source
tests: archive-sim-artifact_round_trips_pct_replay_options_and_reproduces_the_trace.log (1 passed, SHA-256
7a6079e2d930642f6d7ded4751ffc48ddfb9ca6bfec9f97e11f8e91a9bd93340). Historical archive member SHA-256
b93e795bc53f5f764394be5caddbd13847e3744a7fe3f5a7ecd7b776a82dc87c. Candidate archive member SHA-256
66406c3880626e54d7eb82784cb5fe89f374cb9e370cfeb6a4af9368386fd287.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation/harness/artifact.rs

### Decision 289

`tests/simulation/harness/components.rs` · `intentional_divergence`

The upstream test-only classifier compares each declared component history separately. The ordinary
agreeing-components case passed. Godot’s fixed-membership barrier checks survivor authority and canonical
state through docs/peer-session.md and docs/oracle-p2p.md; the source unit test provides no evidence about the
full Godot partition continuation policy. Candidate source tests: archive-sim-components.log (1 passed,
SHA-256 a10e459ac742fe4ca63e588318b333f06767eeca28565e28d07b66ac9d3fa0d6). The member is absent from the
historical archive. Candidate archive member SHA-256
e3c9b34b44d154b158d5b36f94e1ca8e37ab0bae84398518a6ec1bc71a6e7d5b.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation/harness/components.rs

### Decision 290

`tests/simulation/harness/mod.rs` · `intentional_divergence`

Rust's harness adds seeded PCT drive order, run-option-dependent nominal history, component-scoped
confirmation, progress attribution and replacement-slot hot-join/control observations. Godot's
scripts/oracle/p2p_launch.py consumes explicit per-peer schedules twice, with independent canonical shape,
exact reports and bounded minimization. The harness schemas and live-target/removal scheduling are separate.
The local exact candidate simulation selection ran 37 tests with 0 failures (log SHA-256
af8c83c5146350a1166d2d6bac6fe0396b5f1e44c2f5c3cce57cb6ec0ddc02a0). Both exact candidate Godot P2P receipts for
Godot 4.3 and 4.7.2 passed all 67 scenarios. See docs/reference/p2p-profiles.md and docs/oracle-p2p.md for the
committed supported profiles and differing transport scope. Reviewed member SHA-256
bac0a63e51ec8e1b45d5aebfec3fd3e662189b35d5094cd7a3ad269bfa9ad97c. Candidate member SHA-256
47a7fafa5c0653c7c990f0278fa985dc6f50b442e6d80a86af9b15434be1b494.

### Decision 291

`tests/simulation/harness/oracle.rs` · `intentional_divergence`

The Rust oracle adds nominal input/state comparison and stops inferring a freeze mismatch from a survivor that
has not reached the reported cut. Godot's packet and callback comparisons use explicit per-schedule common
history plus the independent scoped donor and cut validators. They compare retained canonical rows at eligible
boundaries; the Rust PCT and optional nominal-model suites remain upstream. The local exact candidate
simulation selection ran 37 tests with 0 failures (log SHA-256
af8c83c5146350a1166d2d6bac6fe0396b5f1e44c2f5c3cce57cb6ec0ddc02a0). Both exact candidate Godot P2P receipts for
Godot 4.3 and 4.7.2 passed all 67 scenarios. See scripts/oracle/drop_history_contract.py and
docs/oracle-p2p.md. Reviewed member SHA-256 29f463f2c1daf231fd97263e5749216c10a59c5c124fb87376aca67a6004a864.
Candidate member SHA-256 422e5e5ea8906f32251c267a77d3d56fcc49ce338404a85c9aead8449071caef.

### Decision 292

`tests/simulation/harness/schedule.rs` · `intentional_divergence`

The Rust test schema now bounds input queue configuration and generates deterministic loss rates in integer
basis points. The pinned digest, basis point and queue-capacity serialization checks passed. The Godot queue
and P2P fixtures own independent schemas and do not use the upstream generator as their scheduler. Candidate
source tests: archive-sim-generated_schedule_digest_is_pinned.log (1 passed, SHA-256
541d8a726e6a997370f316b78497f63ac900fb112d7b68e8cb3a1d21e8a5b1cc);
archive-sim-generated_rate_policies_are_exact_basis_points.log (1 passed, SHA-256
823d4067f179bb798c1baa36b4775fd7f65ac13b27847349bd0dc798dc45bb40);
archive-sim-non_default_input_queue_length_round_trips_and_omits_when_unset.log (1 passed, SHA-256
c257ebb7894d967303d1912c20082f825bf339c7f4db03848a1241697395d7a7). Both candidate queue_launch receipts
passed, SHA-256 4.3 1df6186f3ce6d31a33b90baeaaa2b973ff3eca55ff59c128cf6c8131d2999241, 4.7.2
83d4226b774f852c953b7ab415208dd612ab6eee7a2b52d32e96885926aee828. Historical archive member SHA-256
7cde6df329cb370190b9370f00ce63e39cdbd3128f878dc3ea70416e95d5d4ae. Candidate archive member SHA-256
acc1a8939e799bf0be69e8c7648be1b5fc90024f03ae883d27774b5591fdf2e0.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation/harness/schedule.rs

### Decision 293

`tests/simulation/harness/shrink.rs` · `intentional_divergence`

The source test-only shrinker keeps deterministic attempt order, remaps declared components and respects a
strict runtime delay increase while shrinking. Godot keeps its own identified regression scenarios and trace
format. These tests cover ordinary shrink reproducibility and delay bounds. Candidate source tests:
archive-sim-shrink_result_is_independent_of_runner_speed.log (1 passed, SHA-256
3f1e1ff37a6ee79e965e8cdcad075ef19ded35b8cb409ab569a264cf1f767c65);
archive-sim-runtime_delay_shrinking_uses_strict_increase_floor.log (1 passed, SHA-256
f9e6b477d389dae0ddd9dc87174a0b13f3fd8fc9b7a49384f5a8086e3d0bb9c9);
archive-sim-legacy_delay_shrinking_to_zero_survives_maximum_initial_delay.log (1 passed, SHA-256
f0cd2db736555b3fc41fe4181d8c716f16365c4c27c2160c09b86f6386bfca1c). Historical archive member SHA-256
277ab821c66b5d8ca39556e991de9ca80ea8b74cab1d0d94b5b40a82e9c047b7. Candidate archive member SHA-256
412001e8ceba5f8f9885047a36a1aaca3099b38865eeedd46a8dd745cc3958b2.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation/harness/shrink.rs

### Decision 294

`tests/simulation/pacing_cliff.rs` · `intentional_divergence`

The upstream virtual-time ablations measure prediction headroom, input delay, induced loss and wait guidance
on source-only workload cells. Godot keeps wait guidance advisory and owns separate byte-session liveness and
canonical-state tests under docs/input-exchange.md and docs/reference/p2p-profiles.md. These receipts
establish no cross-runtime pacing curve. Candidate source tests: archive-sim-pacing.log (5 passed, SHA-256
a8052ddb86d3d95c9cc8d04d63afa13ea2a9b363fe561d7014f6fe233961d782). The member is absent from the historical
archive. Candidate archive member SHA-256 c866450035ee569e29e04a785f7e7a0af26fff03f7401a9816e61dd7d076e74e.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/simulation/pacing_cliff.rs

### Decision 295

`tests/simulation/partition_sweep.rs` · `intentional_divergence`

The new upstream Rust sweep classifies declared symmetric cuts and directed faults as recovery, expected
finite failure, defects or invalid evidence. Godot's declared profiles include matched one-way partitions,
bounded heal and rotating fairness with full canonical traces, and a separate fixed-roster timeout/barrier
contract. The upstream full matrix and replayable verdict schema are additional Rust qualification, beyond the
Godot scoped profiles. The local exact candidate simulation selection ran 37 tests with 0 failures (log
SHA-256 af8c83c5146350a1166d2d6bac6fe0396b5f1e44c2f5c3cce57cb6ec0ddc02a0). The selected positive Rust controls
prove the fault premise inventory and the slow-peer recovery oracle. Both exact candidate Godot P2P receipts
for Godot 4.3 and 4.7.2 passed all 67 scenarios. See docs/reference/p2p-profiles.md and docs/oracle-p2p.md for
the committed supported profiles and differing transport scope. Reviewed member SHA-256 absent. Candidate
member SHA-256 ec5c147ccc9e6aac8a7734460143eee6211711301659ffbd18a2ee4dcf1cd98b.

### Decision 296

`tests/simulation/sometimes_state.rs` · `inapplicable`

The changed organic eligibility and seven-window ratchet, bounded shard merge and source-location violations
are Rust nightly fleet artifact contracts. Godot gates its explicit archive-bound schedule and case inventory
in docs/reference/p2p-profiles.md. The Rust organic/targeted counts are absent from the Godot project's
receipt schema. The local exact candidate simulation selection ran 37 tests with 0 failures (log SHA-256
af8c83c5146350a1166d2d6bac6fe0396b5f1e44c2f5c3cce57cb6ec0ddc02a0). The local selection includes retained-ID,
shard completeness, saturation, and seven-window census checks. Reviewed member SHA-256
a96f8af479031ff0a8958c8c8c8b85540b3bf00c7dc2a03112201d6aae08cc41. Candidate member SHA-256
69f62a0c1dadae2a3ab22c0a4e4eb89a7ad5f805d6d43ede452653557a45a29b.

### Decision 297

`tests/stats_alloc_contract.rs` · `inapplicable`

Pins the stats_alloc 0.1.10 process allocator contract that realloc growth is already included in allocated
bytes. Neither the GDScript engine nor the addon exposes that Rust allocator test harness. Exact candidate
Cargo 1.99.1 locked offline with default features disabled passed the allocation contract, representative
two-player smoke, and realloc contract (log SHA-256
bdac1dbcb7e578f590f4ea6fe4db9c33786edbe867ff0969fc29bbeef99aed8e). Godot release allocation evidence has its
own contract in docs/verification-policy.md. Reviewed member SHA-256 absent. Candidate member SHA-256
7f8aabf22a423c9fb55a8c7932c92c8d329e27707f4cdae08e1017768e64fe1d.

### Decision 298

`tests/verification/determinism.rs` · `inapplicable`

The sole change adds a diagnostic to the existing assertion that Rust sync-test checksum history is non-empty.
Godot independently checks owned state bytes and sync-test behavior. Candidate source tests:
archive-sim-verification-test_checksum_history_determinism.log (1 passed, SHA-256
1f07bc22d3bffe02eaef0cdf9565ee37e11823755a14c7bdfac9a56944d75c96). Both candidate launch receipts passed,
SHA-256 4.3 3b90016fda5e0d644ba186470dc1f72f85b043069c8bdafa01f60906c85719e0, 4.7.2
ee84241df4f49537c08e7ef5fc0e4da3b59c47977f122f997a7d113239e5e513. Historical archive member SHA-256
6e209b20598d8f11b219421c411b7f6e7effd54d50da7b77419fb64a37df0013. Candidate archive member SHA-256
39de76dc7dd2c571c3b72bd9df8d1442668516401b61935b8c1b33b6d739b2b1.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/verification/determinism.rs

### Decision 299

`tests/verification/invariants.rs` · `inapplicable`

The sole change adds a diagnostic to the existing non-empty display assertion for a possible InputQueue
invariant violation. The named source test exercised a valid queue. Godot has separate queue diagnostics and
differential evidence. Candidate source tests: archive-sim-verification-test_invariant_violation_detection.log
(1 passed, SHA-256 b8af21b736d8587da0f54d681990be257a46cfb6c497b6151da2e9a37d516593). Both candidate
queue_launch receipts passed, SHA-256 4.3 1df6186f3ce6d31a33b90baeaaa2b973ff3eca55ff59c128cf6c8131d2999241,
4.7.2 83d4226b774f852c953b7ab415208dd612ab6eee7a2b52d32e96885926aee828. Historical archive member SHA-256
aaa718350836751d1615c446fe4c6f52664ecb88756a73a6049a2885aaf02d76. Candidate archive member SHA-256
b9664ef539eb3b690e1cb4a69272f166f1009276a74150e24b0814f8ed590e1a.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/verification/invariants.rs

### Decision 300

`tests/verification/property.rs` · `inapplicable`

The sole change removes an unnecessary clone when the Rust property harness moves a saved-state cell into its
local inventory. The fixed-seed property preserves checksums. Godot validates snapshot ownership separately.
Candidate source tests: archive-sim-verification-prop_sync_layer_checksum_preservation.log (1 passed, SHA-256
e06eb6753b3ee2661872b51857afc5585fb3549e485a7e8b4f709e5ccf102239). Both candidate launch receipts passed,
SHA-256 4.3 3b90016fda5e0d644ba186470dc1f72f85b043069c8bdafa01f60906c85719e0, 4.7.2
ee84241df4f49537c08e7ef5fc0e4da3b59c47977f122f997a7d113239e5e513. Historical archive member SHA-256
50ecda818bd3392c037fededc967a95d1e51806709f711595c20b1c0420e5b13. Candidate archive member SHA-256
101cce91954a7d85a49f945e26a38bfef1644b681b54648f57d627cbce5d6a44.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/verification/property.rs

### Decision 301

`tests/verification/z3.rs` · `intentional_divergence`

The Rust fixed-size Z3 model scopes the comparison primitive to admitted same-basis reports and separately
proves a differing modeled basis suppresses comparison; model-only statements do not cover the actual
production gate. Godot validates its independent diagnostic and queue behavior through real paired receipts
and bounded trace/model checks, including a 64-bit source checksum basis in the v6 oracle, without claiming a
proof of GDScript from the Rust solver. Exact candidate hosted Z3 reported 66 passing cases including both
changed basis checks
(https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046813733/job/140668004322, log
SHA-256 fc8eb51fde44372bab16fe50cf96c5dc109e10c96467537d485487a854a87937). Both exact candidate Godot P2P
receipts for Godot 4.3 and 4.7.2 passed all 67 scenarios. See docs/verification-policy.md and
docs/oracle-p2p.md. Reviewed member SHA-256 541eb8cf8a00dc4dc598e0c7ecc2f9b43e5ff021dfd6dae3bd9fc339677429c6.
Candidate member SHA-256 728572e128a92bada0502293d949b992c2b2b6ff21215db4491b641c04de12ec.

### Decision 302

`tests/wasm-browser-smoke/Cargo.toml` · `inapplicable`

Moves the browser test dependencies into the bare wasm32-unknown-unknown target, makes hot-join/test-probes
opt-in, and upgrades wasm-bindgen-test to 0.3.80. The Godot package targets wasm32-unknown-emscripten and
checks that its release module does not pull wasm-bindgen. The locked release Emscripten feature tree SHA-256
bac911b863e2889b606576df77ccbe40a05c010e06562a5413ac9713c23ea5a3 excludes the fixture crate, wasm-bindgen,
Tokio, hot-join, and test-probes. Local package audit SHA-256
211aad928fc6bfe9ecd7bcccbefb88c9eb6855e7f0ec2cb5494f5635c79a8a6f records the verified candidate native and Web
ZIPs plus actual Chromium, Firefox, and Playwright WebKit exports on both Godot pins. This covers the
test-tool configuration only. Compared archive member SHA-256 values are
9fed817e495629b9572d100a99d7992e9ce12baca7d96af11d83e120a35d104a and
226b4309adcbbc0bb9cb5a4bc6796f0a28850d0126f9f51cf701ab46f844c4ce.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/tests/wasm-browser-smoke/Cargo.toml

### Decision 303

`tests/wasm-browser-smoke/src/lib.rs` · `intentional_divergence`

Exact candidate source CI 46046809665, job 140667990201 ran the wasm-bindgen Chrome suite: 12 passed. The
hosted Godot package matches exercise actual exported Godot and a standalone Rust peer rather than the source
test-only wasm-bindgen browser harness. Its extra feature opt-ins and recording digest scope are independent.
The separate Godot project rehearsal 46072793492 produced 12 digest-verified platform cells, 32 canonical
40-row matches and 32 restore/encoding controls. Its contract selects the source archive and uses fixed-roster
default-feature-free packages. It does not enable the upstream test-only hooks or certified membership/epoch
import. Cross-target source replay is a separate signature and format. Reviewed archive member SHA-256
f449e79fbba3e967f374bc8e0bea6a0f8d4662fb1c6842534560771e7430ce9e and candidate
49569c67540715d7f9ec2a9ca8bc4bd01235271e9984a143a47443ce90046d4f.

### Decision 304

`wiki/API-Contracts.md` · `intentional_divergence`

Wiki mirror of docs/specs/api-contracts.md with the wiki link paths. The upstream API now describes automatic
strict-majority/witness admission, Rust explicit removal with source-epoch, provisional Ready, retry, abort
and fallback rules, and zero-speed terminal spectator drain. Godot documents the matching automatic witness
and protection of the agreed cut while retaining its own authority and all-survivor certificate, an
era/roster-bound operation identity, a conservative timeout on coordinator loss, and a positive catch-up speed
with clean END distinct from selected host loss. The port does not expose the Rust remove_player or zero-speed
APIs. Scope and observed behavior are in docs/peer-lifecycle.md, docs/oracle-p2p.md and docs/spectators.md.
The candidate ordinary drop receipt SHA-256 is
f9d1d94c89c0e44162cc9eb7dd1a8802f600549b161d2e00c4a9645ee6a2b58c, and the isolated failover receipt SHA-256 is
805352d06bfd6119d124d8a2ce03fea55964a5392974b3449a42b256be4a2cd1. The candidate archive passed 67 P2P
scenarios and the source-selected formal handshake and spectator checks on both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929 Reviewed
archive member SHA-256 9de79ca001b1943a85e16cf89b21e5725f0ff607d260acad73b1af3119467ac6 and candidate
6ea093e5799899441dda1f70002815190bbc537257126f79246a7fad3890e694.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/API-Contracts.md

### Decision 305

`wiki/Consensus-Posture.md` · `intentional_divergence`

The source rationale chooses deterministic membership certification with strict-majority, agreed participants,
fallback authority and terminal-epoch fencing. Godot shares the confirmed-prefix and partition safety goals
using its frozen roster, all-survivor certification and terminal timeout. The candidate coordinator-silence
comparison in docs/oracle-p2p.md reproduces the liveness difference, and docs/peer-lifecycle.md covers local
quorum refusal. The optional native boundary does not expose a coordinated-drop guarantee, per
docs/native-backend-migration.md. Archive member SHA-256 reviewed absent, candidate
1ddf3552840241d31b94323944f9b1d53b3808f5c385a00ae33eb4dd99d6f367.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Consensus-Posture.md

### Decision 306

`wiki/Contributing.md` · `inapplicable`

This file records the source GitHub wiki’s contribution and release procedures. The Godot repository owns
those processes through .llm/context.md and .github/workflows/gate.yml. Compared archive member SHA-256 values
are 73efc5f253a689955ec860a2438482053b1a7de5f4e67501491bab5c3ff31171 at the reviewed revision and
339827b0ae77336134f4c52bb8bb06df3a8ed29abd9862aebce2caafc450876f at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Contributing.md

### Decision 307

`wiki/Determinism-Model.md` · `intentional_divergence`

The source documentation replaces generic portability advice with checks on the Rust replay format,
pointer-width serialization and hashing, and exact Rust fault-schedule digests. Godot’s canonical byte and
checksum contract is independent, with explicit little-endian integer handling in
docs/experiments/integer-encoding.md, exact snapshot/checksum width in docs/contracts.md, and its own replay
fixture/interface and profile receipts in docs/oracle-replay.md and docs/reference/p2p-profiles.md. Exact
candidate native fixture tests passed 7/7 and exact source stress-corpus tests passed 11/11. The Godot native
experiment uses a separate editor/package matrix and had six v6 Linux browser matches and two relay rooms in
the rehearsal. Those receipts establish the selected package and game boundary. The source portable binary,
i686/s390x/wasip1 digest runs and Rust generic Hash behavior are not claimed as Godot ports. Fixture log
SHA-256 1e68604b6a27f11581e5d444eacfc4cebb82d5e893438694920b6a97b1c8b4ab, corpus log SHA-256
b24e8aca88753598e7cf4d40c5824e162aad6f5d92ec454124b54fb17da569d1, and native package-audit SHA-256
211aad928fc6bfe9ecd7bcccbefb88c9eb6855e7f0ec2cb5494f5635c79a8a6f. Archive member SHA-256 reviewed
b9eaa20098854ae1625e64eee329a836cb11793f9af49f7c279cc2116226c892, candidate
cccf678cbfd27451e7b5f3a0a28cacbbfeb2b2cfad0d92e5432e694078320cf6.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Determinism-Model.md
Independent related simulation evidence: The upstream edit describes Rust fixed-width wire/hash semantics,
native-memory-slice hashing limits, recorded checksum coverage, and upstream CI target lanes. Godot owns
canonical byte encoding and checksum callbacks in docs/integration.md and documents a separate native Linux
and exported Web matrix in docs/supported.md. The candidate matches the source schedule and trace digests on
this Linux/aarch64 host. These runs do not establish Windows, macOS, i686, s390x or WASI execution. Candidate
source tests: archive-sim-generated_schedule_digest_is_pinned.log (1 passed, SHA-256
541d8a726e6a997370f316b78497f63ac900fb112d7b68e8cb3a1d21e8a5b1cc);
archive-sim-smoke_traces_match_checked_in_cross_architecture_digests.log (1 passed, SHA-256
0cb7fa512f84f2ee90930e62eaaeea50f9156a8bb2fd3bac161f7011749b3ec5);
archive-sim-same_schedule_produces_identical_trace.log (2 passed, SHA-256
72d46712aa64382c4b3f68bd6f6720a5102dffd6771ac120f666b4afeb5c9ccd). Both candidate launch receipts passed,
SHA-256 4.3 3b90016fda5e0d644ba186470dc1f72f85b043069c8bdafa01f60906c85719e0, 4.7.2
ee84241df4f49537c08e7ef5fc0e4da3b59c47977f122f997a7d113239e5e513.

### Decision 308

`wiki/Formal-Specification.md` · `intentional_divergence`

Wiki mirror of docs/specs/formal-spec.md with the wiki link paths. The diff documents source SAFE-7a/b/c token
and latch rules, same-cut provisional Ready digest authorization, terminal-attempt epoch kernels, fixed
fallback and split-view models, and proof-strength limits for Z3/Kani. Godot is explicitly scoped in
docs/verification-policy.md, docs/peer-lifecycle.md and docs/oracle-p2p.md. It protects exposed checksums
through its certified cut, discards departed reports, uses its locally derived roster/era and bounded
closed-operation journal, and keeps exactly one designated coordinator with an all-survivor certificate. On
both engines a delayed surviving report for frame 60 was checked after coordinated cut 65. The v6 fallback
relay source committed while the Godot participants timed out with preserved input history. The checked-in
model projection does not transfer Rust Kani/SMT proof strength or claim fallback consensus parity. The
candidate archive passed 67 P2P scenarios and the source-selected formal handshake and spectator checks on
both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929
Source-revision verification workflow
https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046813733. Reviewed archive member
SHA-256 0fb896f53e7593ded62c799e3dfcff77a79303a50eaf7fb01ac313bef489c660 and candidate
a78a8e4a37e05fa3f63443722b4a1da0bbcd636a63b51ee2e113ef6ca4795e9d.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Formal-Specification.md

### Decision 309

`wiki/Getting-Started.md` · `ported`

The upstream example aborts request processing when saved state is unavailable or a required checksum cannot
be produced. Godot uses typed callback completion instead of a Rust macro. tests/unit/test_driver.gd covers
failed callbacks and unavailable rollback history; tests/unit/test_snapshot_history.gd rejects failed saves
and absent or malformed checksums. docs/native-backend-migration.md defines the same first-failure stop for
the native driver. Archive member SHA-256 reviewed
38ba098727fcd824329012c8708101fa354912fa6faeb6fe657a29704ce08793, candidate
78cb65330d942552eaa12b28645ab44e1f40fafacc62b060aad1318adc164a40.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Getting-Started.md

### Decision 310

`wiki/Migration.md` · `intentional_divergence`

Wiki mirror of docs/migration.md with the wiki link paths. The Rust migration adds a terminal spectator error,
bounded hot-join retry, v3-v6 source wire transitions, and the exercise-census feature. Godot migration
follows its own engine and protocol guides: authenticated clean spectator finishes drain the tail while known
source loss fences playback; the fixed roster excludes hot join and transparent reconnect; GDScript peer wire
and optional Rust room versions are independently negotiated. The source-selected receivers exercised both
current protocol selection and incompatible source/field refusal, and the native profile rehearsal supplied
matching package evidence. The candidate archive passed 67 P2P scenarios and the source-selected formal
handshake and spectator checks on both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929 Candidate
package qualification has 12 digest-verified platform/editor results, 32 canonical 40-row matches and 32
restore/encoding controls.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492 Reviewed archive
member SHA-256 ba69d8cd01a5e8800a5f02916a2be2c2bd812bd5b593f9b635bb9280f1bb76cd and candidate
d2f8b6a4ebb9ddd511c991020dbd007875b149b2e9d3b67d184b263f944a1af4.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Migration.md

### Decision 311

`wiki/Overview.md` · `inapplicable`

The single added row links to the upstream consensus design paper. Godot operators use docs/peer-lifecycle.md
for the supported barrier and docs/oracle-p2p.md for the measured fallback boundary. The index itself adds no
runtime claim. Archive member SHA-256 reviewed
67aae99125374a27ef27de2fc0c5c3e84e0167a6d227b65a19981c2ac62fb666, candidate
c5678b50961f7099da9df0b39ccd490ad74132a39bc11aed0abbce75403f6ec2.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Overview.md

### Decision 312

`wiki/Production-Checklist.md` · `intentional_divergence`

Wiki mirror of docs/production-checklist.md with the wiki link paths. The upstream release checklist ties its
checked-in 4,096-frame portable replay, socket acceptance counters, strict Rust build and extended
mixed-transport corpus, browser suspension probes and Rust misuse examples to the upstream release. The exact
upstream WASI lane printed 4,096 frames, 8,192 requests and both fixture digests; bare browser passed 12
tests, and the Emscripten job ran three tests. Godot release conditions use the independent addon policy in
docs/verification-policy.md, the status-aware reader and final-state checksum of docs/oracle-replay.md, and
the named profiles in docs/reference/p2p-profiles.md. The tested native rooms are a separate 40-row
interoperability claim. No inference about the source mixed-transport throughput or Godot background-tab
release coverage is made from it. Source-revision Rust workflow
https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046809665. Candidate package
qualification has 12 digest-verified platform/editor results, 32 canonical 40-row matches and 32
restore/encoding controls.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492 Reviewed archive
member SHA-256 ef312aa767d8a67b775ab020fddbf9cc7a0fa7a579e5d5997daf230638b1ee74 and candidate
680504d624bac536db68b6f4ae737f57f0607c1c6161a9169f777af57e813483.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Production-Checklist.md

### Decision 313

`wiki/Reconnect-Playbook.md` · `intentional_divergence`

Wiki mirror of docs/reconnect-playbook.md with the wiki link paths. The upstream playbook defines automatic
strict-majority and witness admission, the explicit Rust removal and synchronization paths, an isolated-side
one-way terminal tail bounded by prediction+1, and a rejected acknowledgement-floor experiment. Godot's
automatic timeout matches the agreed-majority rule and its own witnessed-cut contract in
docs/peer-lifecycle.md. Its callable surface keeps the explicit Goodbye fence and excludes transparent
reconnect (docs/supported.md#explicit-exclusions). A scratch deterministic production Godot peer probe used
the same fixture with and without the target's outbound traffic. Both editor pins repeated the same result:
target still received 66 addressed packets, peaked at confirmed frame 12, terminated for missing_quorum, and
the survivors committed cut 5 with identical canonical callback states through confirmed frame 65. The
observed 7-frame tail fits the window-8 plus one bound in this schedule. The connected control had no cut, and
all peers agreed through confirmed frame 84. The source policy's acknowledgement-floor performance
measurements remain source-only. Probe SHA-256
2628dc78e75006d67e17baa285daf89918d07b1ff3f16e244f813b922b682310; fresh-run log digests
4ff11d8e8735f8b32a94f4e02cf42d711860eb2e7024048424d145728c5a568d,
4ff11d8e8735f8b32a94f4e02cf42d711860eb2e7024048424d145728c5a568d,
941e3a3fca28882c08a3f43e312811fbe1b4b863a1db2fefa20f9c0184be94a9,
941e3a3fca28882c08a3f43e312811fbe1b4b863a1db2fefa20f9c0184be94a9. Reviewed archive member SHA-256
c79567c356cfa102ab6a40b797ce19dff35566a4c21ecf009de976027ff10cf9 and candidate
4ac15c176abf9aa91080366cfae04e9065bbc373fd201662ff28b43cba07344a.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Reconnect-Playbook.md

### Decision 314

`wiki/Replay.md` · `ported`

The upstream addition documents confirmed-input service after local sampling stops.
docs/oracle-replay.md#asymmetric-delivery-and-final-recovery documents the selected source and Godot
Driver.recover contract, including re-simulation at boundary 257, idempotent repeat, original confirmed
export, and withholding both final rows. docs/integration.md documents the separate Godot terminal checksum
capture. The upstream examples use Rust replay serialization; Godot continues to use FRRP versions 4, 5 and 6.
Corrected candidate exports are 257/257 without replay desync; historical asymmetric exports are 256/255 with
128/170 replay desync events. Verified paired replay receipt SHA-256 values: 4.3 candidate
ef58d9c9eb8a50b8576a60db0cb4f5a2a49b0c55adb6d62afef9f9fc6b5f29d7, 4.3 historical
c0bcf1ae4dc2dfabb633af5f5dfc4d4324fa77bc9e8fde224f8a8f9ec7e0756b, 4.7.2 candidate
62a9a153a8fb3d17f086c4ed7523e73b72b8d983cd2eef49d8b5294ae3cb68f6, 4.7.2 historical
0447e717a67380975c8bc040be21d3490c8bf115d24d2e66bf3b5de401b812e4. Historical archive member SHA-256
36740bfbd09693c061d4c442bc0383270ddb2b63ae8cba2000271dc04759fa51. Candidate archive member SHA-256
c6c3ba03b27093c0d3b4005210ee632682e94084c692c4643f6bab18403b7453.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Replay.md

### Decision 315

`wiki/Spec-Divergences.md` · `intentional_divergence`

Wiki mirror of docs/specs/spec-divergences.md with the wiki link paths. The source adds a generated
verification-manifest alignment table, classifies mathematical Z3 checks, records narrow runtime handshake
refinement, and names the source spectator models. The Godot project defines proof bounds, non-vacuity and
full trace consumption in docs/verification-policy.md. Its source-selected Godot handshake/spectator checks
bind the model inputs to candidate archive bytes, including the actual positive and rejection witnesses. Its
GDScript barrier and spectator transport deliberately have independent contracts and no Rust Kani/SMT/Loom
parity assertion. The candidate archive passed 67 P2P scenarios and the source-selected formal handshake and
spectator checks on both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929
Source-revision verification workflow
https://github.com/Ambiguous-Interactive/fortress-rollback/actions/runs/46046813733. Reviewed archive member
SHA-256 19db1b2989aea90da32382ed10b89d6d66cf69305b01bc865adfafa79e30400c and candidate
53cc0c4d7de1e9dbc000f44e79dbd02b2a22100ad6fd2d88cd08fcb4fc40e630.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Spec-Divergences.md

### Decision 316

`wiki/Telemetry.md` · `inapplicable`

These hunks document the upstream SocketMetrics field and the opt-in socket trait method. Godot owns direct
and relay routing at the native boundary, including the distinct receive_native_result pressure codes in
docs/native-backend-migration.md. This checkout does not expose the source SocketMetrics API to games. Native
source provenance is verified by experiments/gdextension/verify_source.py. Archive member SHA-256 reviewed
44004357365e4330013bd3842daf9b8baf0cd9858b4d90dd1e59ad847d5281f1, candidate
d387bf8d1e42978d31465fb2957c7e533cf44e09071cf43364e60ae34c7613ed.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Telemetry.md

### Decision 317

`wiki/Threat-Model.md` · `intentional_divergence`

The changed threat-model passages add source UDP adapter counters and explicitly distinguish adapter
acceptance from protocol enqueue demand. The actual Godot native Socket implementation in
experiments/gdextension/src/peer.rs implements the send and receive methods and uses the trait’s zero-metrics
default; the driver reports bounded Accepted/Rejected/Full results. The GDScript adapter requires an
attributed sender and bounded packet work, reports ACCEPTED, BACKPRESSURE or failure, and defines ACCEPTED as
local ownership. See docs/contracts.md#transport-boundary and docs/signalfish-relay.md. This classifies the
different telemetry and ownership contract. It does not generalize a socket or packet cap to attack
resistance. Archive member SHA-256 reviewed a43aa0c1b1874a1a86a1581236d96392298ad38de4460776d38e28a102046175,
candidate 67ba40635edf0f3ca59412a8e5cb3d3e6afa96dcf06f4a3d0e930c2e745a95f7.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Threat-Model.md

### Decision 318

`wiki/Tuning.md` · `intentional_divergence`

Wiki mirror of docs/tuning.md with the wiki link paths. These upstream measurements describe the Rust stage
and configuration, including 16-peer timing budgets, named P2P pacing cells, transport queue/counter bounds,
the acknowledgement-floor penalty under the named asymmetric and poor network workloads, and the 66-row fleet
ledger. Godot's supported envelope remains 2-8 fixed players and documented fault/delay/window cases in
docs/reference/p2p-profiles.md. Godot benchmarks use their own engine/host/workload, reproducible checksums
and measured budget policy in docs/experiments/session-hot-path-performance.md and
docs/verification-policy.md. The exact source PR sweep and five pacing cases were green in targeted source
runs. These timings, fault-fleet coverage and throughput thresholds are specific to their source lanes and are
not imported as Godot support. Run log SHA-256
a8052ddb86d3d95c9cc8d04d63afa13ea2a9b363fe561d7014f6fe233961d782 and
1046d548ed66eacd66f33e30423243f28d58584f6d23d37976ce97666833a32b. The candidate archive passed 67 P2P
scenarios and the source-selected formal handshake and spectator checks on both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929 Reviewed
archive member SHA-256 156353df117389e348f097593e93077a41a7731327f22cfa0374d2a1cb9d79ed and candidate
653ef417a235691f4432851773c750d644736eb48202fabe8cc80f7964ad7cac.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/Tuning.md

### Decision 319

`wiki/User-Guide.md` · `intentional_divergence`

Wiki mirror of docs/user-guide.md with the wiki link paths. This is the Rust application guide for
recovery-only service, fallible macros and typed Rust errors, Tokio and the exercise census, coordinated
removal with epoch/authority/fallback behavior and spectator truncation. The deployed Godot interfaces in
docs/session.md, docs/peer-lifecycle.md and docs/spectators.md own analogous recovery, safe ordered callback
completion and fail-closed outcomes. They use a single configured source for playback, a fixed roster,
negotiated byte protocol, and a separately validated state checksum domain. The reference candidate completed
257 decoded final rows for both peers, and its positive and withheld cases preserve the observed 257 and
256/255 boundaries. The extension package retains its separately qualified fixed-membership scope. The
candidate archive passed 67 P2P scenarios and the source-selected formal handshake and spectator checks on
both Godot editor pins.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546#issuecomment-7229312929 Candidate
package qualification has 12 digest-verified platform/editor results, 32 canonical 40-row matches and 32
restore/encoding controls.
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/46072793492 Reviewed archive
member SHA-256 cd1dd80458e2552edad315da7ef2e116d3eec2504536199d0cc374d944a633ce and candidate
ead8246dc5153b4a5dcc5f7b7246d39ee10663147ca386ed811d750048ddcd2c.
https://github.com/Ambiguous-Interactive/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/User-Guide.md

### Decision 320

`wiki/_Sidebar.md` · `inapplicable`

This file records the source GitHub wiki’s navigation. The Godot repository owns those processes through
.llm/context.md and .github/workflows/gate.yml. Compared archive member SHA-256 values are
3b460719a27b34666fa58b5ab0b10f927f238d7455d37b2107d9cac8e9b93b34 at the reviewed revision and
04d7d6f7af95ad75732c757ef55ac43b1d774c22494a963b5d1bf6c03ebd3fb4 at the candidate.
https://github.com/wallstop/fortress-rollback/blob/25e8020d1a5fd40c4f16b37f97b5ec5329a8566d/wiki/_Sidebar.md
