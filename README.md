# arkify-automation

Automates kernel point-release rebases and COPR builds for the arkify targets in
[LorbusChris/linux](https://github.com/LorbusChris/linux):

| target | device | arch | COPR | consumption branch |
|---|---|---|---|---|
| sc7280 | Fairphone 5 | aarch64 | [@mobility/sc7280](https://copr.fedorainfracloud.org/coprs/g/mobility/sc7280/) | `copr-sc7280` |
| surface | Microsoft Surface | x86_64 | [@mobility/surface](https://copr.fedorainfracloud.org/coprs/g/mobility/surface/) | `copr-surface` |

The manual procedure this encodes is `docs/arkify-sop.md` on the kernel repo's
`arkify-local-infra-*` branches. Read that first; this repo is just SOP §2–§3
run by cron.

## How it works

**Builds** need no credentials here: each COPR package's committish is a stable
*consumption branch*, and a GitHub webhook on the kernel repo notifies COPR on
push. COPR only rebuilds when the pushed ref ends with the committish
(`packages_logic.py: ref.endswith(committish)`), so pushing a version-pinned
branch never triggers anything — only the consumption push does:

```
git push fork linux-X.Y.Z-<target>-arkify:copr-<target>   # the release gesture
```

**Rebases** run from [.github/workflows/rebase.yml](.github/workflows/rebase.yml)
(daily cron + manual dispatch), in a Fedora container (arkify requires Fedora):

1. `scripts/detect.sh` — statelessly compares the highest
   `linux-X.Y.Z-<target>-arkify` branch against
   [kernel.org/releases.json](https://www.kernel.org/releases.json) for each
   target's `SERIES`.
2. `scripts/rebase-target.sh` — SOP §2–§3: rebase the patch stack onto the new
   tag (conflict ⇒ open an issue, touch nothing), seed the infra branch from the
   same-target predecessor, run arkify, verify the SOP §8 checklist, smoke-test
   `make dist-srpm`, then push the pinned + infra branches and fast-forward the
   consumption branch — which triggers the COPR build via webhook.

**Stays manual** (the workflow only opens notify issues):
new-series bring-up (SOP §7; then bump `SERIES` in `targets/<target>.env`),
upstream patch-stack resyncs, and any rebase conflict.

## Setup

- Secret `PUSH_TOKEN`: fine-grained PAT, `contents: write` on
  `LorbusChris/linux` only.
- COPR side (already done, for the record): package committish = consumption
  branch, `--webhook-rebuild on`, and the per-project GitHub webhook URL
  (COPR project → Settings → Integrations) added to the kernel repo's webhooks.

## Rehearsal

`workflow_dispatch` with `dry_run: true` pushes `rehearsal/*` refs instead of
the real branches and never touches the consumption branch. Compare
`rehearsal/linux-X.Y.Z-<target>-arkify^{tree}` against a manual run to validate
changes to these scripts.
