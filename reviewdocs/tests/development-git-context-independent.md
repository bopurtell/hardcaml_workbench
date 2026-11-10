# Git-context independent verification commands

Run from `hardcaml_workbench`; fresh `/tmp/opencode` evidence paths are mandatory.
No command below uses the user's store as a mutation target. Scripts retain raw
stdout/stderr and command receipts. See
`docs/development_git_context_independent_review.md` for results and limitations.

```sh
python3 -B scripts/review-development-git-context.py \
  --evidence /tmp/opencode/development-git-independent-baseline-02

opam exec --switch=5.2.0+ox -- python3 -B scripts/review-development-git-consumers.py \
  --store /tmp/opencode/development-git-independent-store-01 \
  --evidence /tmp/opencode/development-git-consumers-independent-01

# Final private refresh after the owner's helper correction.
opam exec --switch=5.2.0+ox -- python3 -B scripts/review-development-git-consumers.py \
  --store /tmp/opencode/development-git-independent-store-01 --refresh-private \
  --evidence /tmp/opencode/development-git-consumers-independent-03

opam exec --switch=5.2.0+ox -- python3 -B scripts/review-development-stage-preflight.py \
  --store /tmp/opencode/development-git-independent-store-01 \
  --evidence /tmp/opencode/development-git-stage-independent-06

opam exec --switch=5.2.0+ox -- python3 -B scripts/test-development-capture-smoke.py \
  --store /tmp/opencode/development-git-independent-store-01 \
  --evidence /tmp/opencode/development-git-native-independent-02

python3 -B scripts/review-development-git-receipts.py \
  --stage /tmp/opencode/development-git-stage-independent-06 \
  --store /tmp/opencode/development-git-independent-store-01 \
  --evidence /tmp/opencode/development-git-receipts-independent-03

python3 -B scripts/review-development-git-context.py \
  --evidence /tmp/opencode/development-git-independent-final-02 \
  --compare /tmp/opencode/development-git-independent-baseline-02/receipt.json
```

All actual Dune commands use explicit `-j2`, switch5.2.0+ox and private build roots.
The installed-library consumer build holds `/tmp/opencode/asic-pt7-build.lock`;
capture/source builds use the owner's `/tmp/opencode/example-pt7-build.lock` and
app capture uses `/tmp/opencode/workbench-pt8-build.lock`.
`reviewdocs/tests/git-context-stage-prepare.ml` is copied into the private consumer
root and linked to the immutable installed library. Production modules are not
copied, edited, recompiled, or substituted to change revision-validation policy.
