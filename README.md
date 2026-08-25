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
   target's `SERIES`. A stable point release is queued **only once knurd42's
   `arkify-infra-stable-X.Y` branch exists** — the sign that the Fedora ark
   infrastructure can build that series. Until then a "waiting for ark infra"
   issue holds the rebase and later runs proceed automatically the day the
   branch appears, so we never rush ahead of the ark infra. (Deliberately NOT
   gated on the kernel series Fedora itself ships: our one branch feeds F44,
   F45 and rawhide chroots, which span multiple series, and a newer stable
   kernel on older Fedora userspace is exactly the kernel-vanilla use case.
   The gate applies to forced dispatches too — to truly override it, run the
   SOP by hand.)
2. `scripts/rebase-target.sh` — SOP §2–§3: rebase the patch stack onto the new
   tag (conflict ⇒ open an issue, touch nothing), seed the infra branch from the
   same-target predecessor, run arkify, verify the SOP §8 checklist, smoke-test
   `make dist-srpm`, then push the pinned + infra branches and fast-forward the
   consumption branch — which triggers the COPR build via webhook.

**Stays manual** (the workflow only opens notify issues):
new-series bring-up (SOP §7; then bump `SERIES` in `targets/<target>.env`),
upstream patch-stack resyncs, and any rebase conflict.

## Notifications

Everything reports through issues in this repo:

| event | channel |
|---|---|
| latest COPR build status, both targets | the persistent **“COPR build dashboard”** issue — body edited in place every 6h by [copr-watch](.github/workflows/copr-watch.yml); a comment (→ notification) is added only on state changes, so each build success/failure pings exactly once |
| COPR build **failed** | one issue per failed *rebase* — “\[target\] Kernel Release vX.Y.Z failed to build” — collecting every failed build of that release (first in the body, later ones as comments, deduplicated by build id). Solve and close it manually; a further failure of the same release reopens it, a different release opens a fresh issue |
| rebase conflict / rebase job failure | issue with the conflicting files, plus GitHub’s built-in failed-scheduled-workflow email |
| new upstream series appeared | notify-only issue |
| point release held for ark infra | "waiting for arkify-infra-stable-X.Y" issue; resolves itself on a later run, close it once the build lands |
| deploy key stopped authenticating | issue from the daily health probe |

Successful rebases show up as the green run’s job summary and, once COPR
finishes, as a dashboard transition comment. The copr-watch workflow needs no
credentials — the COPR API is public.

## Setup

- [config.env](config.env) — `KERNEL_REPO_SLUG` names the kernel repository
  everything operates on (branches, deploy key, health check). Change it there;
  nothing else hardcodes the repo.
- Secret `DEPLOY_KEY`: the private half of an SSH **deploy key** on
  `LorbusChris/linux` (repo Settings → Deploy keys, *allow write*). Deploy keys
  never expire, so there is no renewal treadmill; the `detect` job additionally
  SSH-probes the key **daily** and opens an issue the day it stops
  authenticating (revoked/deleted), so breakage surfaces long before a release
  needs it. To rotate: `ssh-keygen -t ed25519 -N ""`, add the public half as a
  new deploy key, `gh secret set DEPLOY_KEY -R LorbusChris/arkify-automation <
  private-key-file`, delete the old key.
- COPR side (already done, for the record): package committish = consumption
  branch, `--webhook-rebuild on`, and the per-project GitHub webhook URL
  (COPR project → Settings → Integrations) added to the kernel repo's webhooks.

## Rehearsal

`workflow_dispatch` with `dry_run: true` pushes `rehearsal/*` refs instead of
the real branches and never touches the consumption branch. Compare
`rehearsal/linux-X.Y.Z-<target>-arkify^{tree}` against a manual run to validate
changes to these scripts.
