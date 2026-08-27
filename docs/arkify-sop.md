# SOP: rebasing and re-arkifying a downstream kernel branch

How we keep a downstream kernel tree (sc7280/Fairphone 5 today, linux-surface
next) building Fedora RPMs in COPR via
[arkify](https://gitlab.com/knurd42/linux/-/tree/arkify-arkify).

arkify bulk-imports the Fedora [kernel-ark](https://gitlab.com/cki-project/kernel-ark)
packaging infrastructure into an arbitrary kernel tree so that `make dist-srpm`
works. It is re-run after every rebase, and **it overwrites `redhat/`,
`makefile`, `Makefile.rhelver` and `.copr/` every time it runs**. Everything
below follows from that one fact.

This document lives here, in
[LorbusChris/arkify-automation](https://github.com/LorbusChris/arkify-automation),
next to the scripts that implement it — §9 describes the automation that runs
§2–§3 for you. It used to be kept byte-identical on each
`arkify-local-infra-*` branch in the kernel repo; those now carry only a stub
pointing here, because three hand-synced copies drifted in practice.

---

## 1. The branch model

Three branches per build target:

| Branch | Holds | Managed by |
| --- | --- | --- |
| `<target>` | upstream tag + our kernel patches + one `bulk import ark-infra` commit | us (patches), arkify (import commit) |
| `arkify-local-infra-<target>` | **all** downstream packaging changes | arkify creates/rebases, we commit onto it |
| `arkify-local-upstream-<target>` | nothing of ours — it is just the upstream tag | arkify, force-updated each run |

The rule that matters:

> Anything you would edit under `redhat/`, `.copr/` or `Makefile.rhelver` goes on
> the **infra** branch, never on the target branch.

A change committed on top of `bulk import ark-infra` on the target branch looks
fine until the next arkify run, which `rm -rf`s those paths and re-extracts them
from the infra branch — silently reverting it. On the infra branch the same
change is instead rebased onto the newer ark-infra by arkify and re-imported for
you, using normal git merge machinery.

Consequence: a healthy target branch is exactly *upstream tag + kernel patches +
one import commit*. No packaging fixups on top.

---

## 2. Rebasing onto a new upstream tag

```bash
# 0. arkify refuses to run on a dirty tree, and counts untracked files as dirty.
#    Nested checkouts/symlinks belong in .git/info/exclude (note: a symlink needs
#    a pattern WITHOUT a trailing slash - "/mutter", not "/mutter/").
#
#    A previous "make dist-srpm" leaves ~670 generated files under redhat/
#    (configs/kernel-*.config, rpm/, scripts/uki_addons/, tarballs). They are
#    tracked on the branch you built on, but become untracked the moment you
#    switch to a branch that has no redhat/ yet - and then block arkify. Save
#    any SRPM you care about first; everything there is regenerable.
git status                       # must say "nothing to commit, working tree clean"
rm -rf redhat                    # only when redhat/ is fully untracked - check:
git ls-files redhat | wc -l      # must print 0 before you do that

# 1. Keep a way back.
git tag backup/<target>-<old-tag> <target>

# 2. Branch from the last *kernel* commit, i.e. the commit below
#    "bulk import ark-infra" - we do not want to carry the old import forward.
git checkout -b <new-target> <target>~N          # N = number of arkify/packaging commits

# 3. Rebase the patch stack.
git rebase --onto <new-tag> <old-tag>
```

Do **not** pass `--empty=drop`. Some downstream trees (sc7280) use intentionally
empty `-------------` commits as patch-series separators; git keeps
originally-empty commits by default and dropping them mangles the series.

git will automatically drop patches whose contents reached the new tag upstream,
reporting `patch contents already upstream`. Read that list — it is the cheapest
signal that one of our patches landed.

Verify:

```bash
git log --oneline <new-tag>..HEAD | wc -l                          # expected count
git log --oneline <new-tag>..HEAD --grep='^-------------' | wc -l  # separators survived
git describe --tags --abbrev=0 HEAD                                # == <new-tag>
```

Predict the conflict surface up front — usually only a handful of files:

```bash
comm -12 <(git diff --name-only <old-tag> <target> | sort -u) \
         <(git diff --name-only <old-tag> <new-tag> | sort -u)
```

---

## 3. Re-arkifying

arkify derives its helper branch names from the *current branch name*. With a
version-pinned target name (`linux-7.1.10-sc7280-arkify`) every stable bump gets
a fresh, empty `arkify-local-infra-*` — so seed it from the previous one first,
or the customisations are lost:

```bash
git branch arkify-local-infra-<new-target> arkify-local-infra-<old-target>
```

arkify then rebases that branch onto the appropriate new `arkify-infra-<kind>-<date>`
tag on its next run. (With a stable target name — `linux-7.1.y-…` — this step
does not apply; arkify just updates the same helper branches.)

Seeding also means arkify skips the whole two-pass dance: the customisations are
already on the infra branch, so a single arkify run both rebases them and imports
them, and you get exactly one `bulk import ark-infra` commit.

> **Seeding trap.** arkify applies its `local ark-infra configuration` sed
> (`PATCHLIST_URL=none`, `RELEASED_KERNEL=1`, `VERSION_ON_UPSTREAM=1`) **only when
> it creates an infra branch**. A seeded branch never sees it. Any of those
> settings that happened to already match the *old* base carries no diff hunk, so
> it silently reverts to whatever the *new* base ships.
>
> This bit us going 7.1.10 → 7.2.0: `stable-X.Y` ark-infra ships
> `RELEASED_KERNEL:=1` but `mainline` ark-infra ships `0`, so the value flipped to
> `0` with nothing in the log to show for it. They are now pinned explicitly in
> our own `downstream: ark-infra customisation` commit. After any seeded run,
> diff the three against the previous target:
>
> ```bash
> git show <old-target>:redhat/Makefile.variables | grep -nE '^PATCHLIST_URL|^RELEASED_KERNEL|VERSION_ON_UPSTREAM \?='
> grep -nE '^PATCHLIST_URL|^RELEASED_KERNEL|VERSION_ON_UPSTREAM \?=' redhat/Makefile.variables
> ```

Then:

```bash
curl --silent 'https://gitlab.com/knurd42/linux/-/raw/arkify-arkify/arkify' | bash
```

### Fetch the arkify refs yourself first

arkify's own `git fetch arkify` is cheap, but it needs the
`arkify-infra-<kind>-2*` **tags** present locally to pick a matching ark-infra
snapshot. Never do a blanket `git fetch arkify --tags` — the remote is a
kernel-ark fork and that pulls its entire tag set (minutes). Fetch only what is
needed (seconds):

```bash
for b in arkify-fixes-<kind> arkify-infra-<kind> arkify-upstream-<kind>; do
    git remote set-branches --add arkify "$b"
done
git fetch arkify "refs/tags/arkify-infra-<kind>-*:refs/tags/arkify-infra-<kind>-*" \
                 "refs/tags/arkify-fixes-<kind>-*:refs/tags/arkify-fixes-<kind>-*"
git fetch arkify
```

### Check it picked the right infrastructure

`<kind>` is derived from the tree, not from you:

| Tree | `<kind>` |
| --- | --- |
| `SUBLEVEL != 0` (released stable, e.g. 7.1.10) | `stable-X.Y` |
| `SUBLEVEL == 0` / `-rc` | `mainline` |
| has `Next/SHA1s` | `next` |

```bash
git describe --tags --abbrev=0 arkify-local-infra-<new-target>   # arkify-infra-stable-7.1-YYYY-MM-DD
git describe --tags arkify-local-upstream-<new-target>           # == <new-tag>
```

A `stable-*` tree that reports `arkify-infra-mainline-*` means the infra branch
was inherited from a differently-versioned target — ark-infra from the wrong era
often fails to build.

If arkify prints a **fixes** warning, cherry-pick the listed commits onto the
target branch; they are what kernel-ark needed to build on Fedora at that point.
No warning means `arkify-fixes-<kind>` is identical to upstream.

### Two-pass flow for a brand-new infra branch

1. Run arkify once. It creates the helper branches and a first import.
2. `git checkout arkify-local-infra-<new-target>`, apply the customisations
   (§4, §5), commit.
3. `git checkout <new-target>`, run arkify again to import them.

---

## 4. The `UPSTREAM_BRANCH` trap

This is the one that breaks COPR, and it is worth understanding rather than
re-discovering.

On every import arkify seds `redhat/Makefile.variables`:

```
UPSTREAM_BRANCH ?= arkify-local-upstream-<target>
```

That branch exists **only in your local clone**. `redhat/Makefile` does:

```make
UPSTREAM := $(shell $(GIT) rev-parse -q --verify origin/$(UPSTREAM_BRANCH) || \
                    $(GIT) rev-parse -q --verify $(UPSTREAM_BRANCH))     # :207
ifeq ($(UPSTREAM),)
    $(error "Missing an $(UPSTREAM_BRANCH) branch")                      # :227
endif
```

COPR clones a single branch, so neither lookup resolves and the SRPM build dies
at `dist-srpm`. This is why the build appears to need a second branch pushed.

It does not. `UPSTREAM_BRANCH` is only ever fed to `git rev-parse`, so a **tag**
works, and every stable kernel tag is already in the repo. Append to
`redhat/Makefile.variables` on the infra branch:

```make
override UPSTREAM_BRANCH = $(MARKER)
```

Why this exact form:

- `override` — arkify's sed is anchored at `^UPSTREAM_BRANCH`, so a line
  starting with `override` is not matched and **survives every re-import**. It
  also beats the earlier `?=` and any command-line assignment. No post-import
  fixup commit is ever needed.
- `$(MARKER)` — `redhat/Makefile:193` already computes
  `MARKER := v<VERSION>.<PATCHLEVEL>.<SUBLEVEL>` from the tree's own top-level
  `Makefile`, before `UPSTREAM` is resolved at `:207`. So it resolves to the
  current upstream tag and keeps tracking it across future rebases with no edit.

With this in place `merge-base(HEAD, v7.1.10) == v7.1.10`, `git describe` returns
an exact tag, `SNAPSHOT=0`, and the NVR is a clean
`kernel-7.1.10-<RHEL_RELEASE><DISTLOCALVERSION><DIST>`.

**Released-stable trees only.** For `-rc`/stable-rc or mainline snapshots, set
`UPSTREAM_BRANCH` to a real ref instead: `MARKER` is not yet defined where
`redhat/Makefile:175` reads `UPSTREAM_BRANCH` to build `STABLERC_MARKER`.

Prove the single-branch property rather than assuming it:

```bash
git clone --single-branch --branch <new-target> file://$PWD /tmp/onebranch
cd /tmp/onebranch && git fetch --tags origin
make NO_CONFIGCHECKS=1 DIST=.fc$(rpm -E %fedora) dist-srpm
```

---

## 5. Per-target knobs (all on the infra branch)

| Where | What | sc7280 | linux-surface |
| --- | --- | --- | --- |
| `redhat/Makefile.variables` | `DISTLOCALVERSION` | `.sc7280` | `.surface` |
| `redhat/Makefile.variables` | `override UPSTREAM_BRANCH` | `$(MARKER)` | `$(MARKER)` |
| `redhat/Makefile.variables` | `RELEASED_KERNEL` | `1` (pinned, see seeding trap) | `1` |
| `Makefile.rhelver` | `RHEL_RELEASE` | `1001` | pick a distinct value |
| `redhat/configs/**` | one file per `CONFIG_*` symbol | FP5 hardware | Surface hardware |
| `.copr/Makefile` | git identity, `DIST` | shared | shared |

arkify seeds `DISTLOCALVERSION` from `whoami` — always fix it, or your RPMs are
named after your login.

Keep `.copr/Makefile`'s dist dynamic so one branch builds on any Fedora release:

```make
make NO_CONFIGCHECKS=1 DIST=.fc$(shell rpm -E %fedora) UPSTREAMBUILD_GIT_ONLY=0 dist-srpm
```

`.copr/` is in the kernel's `.gitignore`; stage it with `git add -f`.

### Notes on `redhat/configs/`

One file per symbol, most-specific path wins:
`common/generic` < `fedora/generic` < `fedora/generic/arm/aarch64`.

When porting a config commit across ark-infra generations, re-check each entry
instead of replaying the diff — upstream moves entries between levels and
changes defaults. Two real examples from the 6.19 → 7.1 port:

- `CONFIG_TOUCHSCREEN_GOODIX_BERLIN` had been carried for releases despite no
  such Kconfig symbol existing (only `_CORE`, `_I2C`, `_SPI`) — a silent no-op.
- `CONFIG_VIDEO_S5KJN1` had meanwhile become `=m` in `fedora/generic`, making the
  aarch64 entry redundant. Keep it anyway: an explicit entry at the level you
  care about cannot be flipped out from under you by an ark-infra update.

Also verify the symbol actually exists in *your* tree, since downstream patches
add some of them:

```bash
git grep -n '^\(menu\)\?config <SYMBOL>$' <target> -- '*Kconfig*'
```

---

## 6. Building and shipping

```bash
make NO_CONFIGCHECKS=1 DIST=.fc$(rpm -E %fedora) UPSTREAMBUILD_GIT_ONLY=0 dist-srpm
mock -r fedora-<rel>-aarch64 redhat/rpm/SRPMS/kernel-*.src.rpm
```

`dist-srpm` only assembles a tarball and a spec — it does not compile. On an
x86_64 workstation without an aarch64 cross-toolchain, the first actual compile
happens in mock/COPR on an aarch64 builder. Budget for that.

Push, then release by fast-forwarding the consumption branch (§9):

```bash
git push fork <new-target>
git push fork arkify-local-infra-<new-target>   # backup only, NOT a build input
git push fork <new-target>:copr-<target-name>   # THE release gesture: triggers COPR
```

Keep the previous target branch on the fork until the first COPR build is green,
then delete it.

---

## 7. linux-surface specifics

> **The surface and sc7280 builds are independent.** They share this recipe and
> nothing else. The only git history they have in common is the upstream release
> tag they are both based on (`v7.2`) and the upstream ark-infra tag arkify picks
> (`arkify-infra-mainline-2026-08-18`). Do **not** seed one's infra branch from
> the other: it drags the wrong device's configs along and, worse, skips arkify's
> create-time sed (see the seeding trap in §3). Let arkify create each infra
> branch itself and apply the customisations independently.
>
> sc7280 builds **aarch64 only** (Fairphone 5); surface builds **x86_64 only**.
> That is enforced by COPR chroot selection, not by the spec — ark's stock arch
> handling is left alone.

The surface *patch set* lives in a separate repo,
[linux-surface/linux-surface](https://github.com/linux-surface/linux-surface):
`patches/<ver>/NNNN-*.patch` plus `configs/surface-<ver>.config`. The local
`arkify-copr` / `wip-arkify` branches are that repo, not a kernel tree.

Building the target branch:

```bash
# the patch files are concatenated `git format-patch` output, so git am works
git checkout -b linux-<ver>-surface-arkify <upstream-tag>
git am /path/to/patches/<ver>/*.patch
```

For a series still under review, fetch the PR head directly rather than
cherry-picking from a fork:

```bash
git fetch https://github.com/linux-surface/linux-surface refs/pull/<N>/head:pr<N>
for f in $(git ls-tree --name-only pr<N> patches/<ver>/ | sort); do
    git show pr<N>:$f > /tmp/surface-patches/$(basename $f)
done
```

Cross-check the result against the previous series before trusting it:

```bash
diff <(git log --format='%s' <old-tag>..surface-<old> | sort) \
     <(git log --format='%s' <new-tag>..HEAD | sort)
```

Configs: `configs/surface-<ver>.config` is a *fragment* appended to Fedora's
config by linux-surface's own packaging. Under ark you only need the entries
that actually differ — for 7.2, 35 of its 42 symbols were already correct,
because Fedora carries the Surface Aggregator stack and IPU3 cameras upstream.
Audit each per §5 rather than copying the fragment wholesale, and pay attention
to entries that exist only for another arch (`APDS9960` had an aarch64 override
but no x86 one) and to stale CVE workarounds carried forward between releases.

The surface tree is x86_64, so a local `make dist-srpm` **and** a local mock
build are both feasible on an x86_64 workstation, unlike sc7280.

---

## 8. Checklist

```bash
# after rebase
git log --oneline <new-tag>..HEAD | wc -l
git log --oneline <new-tag>..HEAD --grep='^-------------' | wc -l
git describe --tags --abbrev=0 HEAD

# after arkify
git describe --tags --abbrev=0 arkify-local-infra-<target>     # right kind + recent date
git describe --tags arkify-local-upstream-<target>             # == <new-tag>
git show HEAD:redhat/Makefile.variables | grep -E 'DISTLOCALVERSION|override UPSTREAM_BRANCH'
git show HEAD:Makefile.rhelver | grep RHEL_RELEASE
git show HEAD:.copr/Makefile | grep 'rpm -E %fedora'
git log --oneline -1                                           # "bulk import ark-infra" on top

# packaging
make NO_CONFIGCHECKS=1 DIST=.fc$(rpm -E %fedora) UPSTREAMBUILD_GIT_ONLY=0 dist-srpm
ls redhat/rpm/SRPMS/                                           # expected NVR

# the single-branch property
git clone --single-branch --branch <target> file://$PWD /tmp/onebranch
cd /tmp/onebranch && git fetch --tags origin && make NO_CONFIGCHECKS=1 dist-srpm
```

---

## 9. Automation

[LorbusChris/arkify-automation](https://github.com/LorbusChris/arkify-automation)
runs §2–§3 of this document on a daily cron (GitHub Actions, Fedora container).
It exists so a kernel point release normally needs **no human at all**; read
this section to know where the machine stops and you start.

### Build side — consumption branches + webhooks, no credentials

Each COPR package's committish is a stable *consumption branch*, and a GitHub
webhook on the kernel repo notifies COPR on push:

| target | COPR package | consumption branch |
|---|---|---|
| sc7280 | `@mobility/sc7280` / `kernel` | `copr-sc7280` |
| surface | `@mobility/surface` / `kernel` | `copr-surface` |

COPR only rebuilds when the pushed ref **ends with** the committish
(frontend `packages_logic.py`: `ref.endswith(committish)`), which is exactly why
version-pinned branches never trigger builds and the consumption push does:

```bash
git push fork linux-X.Y.Z-<target>-arkify:copr-<target>   # the release gesture
```

That line is the whole release action — for you and for the automation alike.
No COPR tokens live anywhere; the webhook (COPR project → Settings →
Integrations, added to the kernel repo's GitHub webhooks) carries the trust.

### Wiring (or re-wiring) the webhooks

The Integrations page is the manual route; the scriptable one (done
2026-08-25 for both kernel targets, and for pocketblue-packages feeding
`@mobility/{common,surface,sc7280}`):

```bash
# 1. The webhook URL is /webhooks/github/<project-id>/<secret>/. The API
#    exposes the secret only through generate — which also ROTATES it, so
#    re-running invalidates any hook installed with the old URL.
python3 - <<'EOF'
from copr.v3 import Client
c = Client.create_from_config_file()          # auth from ~/.config/copr
w = dict(c.webhook_proxy.generate("@mobility", "surface"))
print(f"https://copr.fedorainfracloud.org/webhooks/github/{w['id']}/{w['webhook_secret']}/")
EOF

# 2. Install it as a push webhook on the source repo:
gh api repos/LorbusChris/linux/hooks -f name=web -F active=true \
  -f 'events[]=push' -f 'config[url]=<URL>' -f 'config[content_type]=json'

# 3. Rebuild-on-push is gated per package by its flag:
copr-cli edit-package-scm @mobility/surface --name kernel \
  --clone-url https://github.com/LorbusChris/linux --commit copr-surface \
  --method make_srpm --webhook-rebuild on
```

GitHub's creation ping should then show `last_response: 200` in
`gh api repos/<repo>/hooks`. For monorepos (pocketblue-packages), COPR
rebuilds only the packages whose subdirectory the pushed commits touched —
one webhook serves the whole repo.

### Rebase side — what the workflow does

Daily, per target (`targets/<target>.env` in the automation repo):

1. Detect: highest existing `linux-X.Y.Z-<target>-arkify` branch vs
   [kernel.org/releases.json](https://www.kernel.org/releases.json) for the
   target's `SERIES`. Stateless — git is the state. A stable point release is
   queued only once knurd42's `arkify-infra-stable-X.Y` branch exists — until
   then a "waiting for ark infra" issue holds it, so builds never rush ahead
   of the Fedora ark infrastructure. (Deliberately not gated on the series
   Fedora itself ships: one branch feeds chroots spanning several series, and
   a newer stable kernel on older Fedora userspace is the normal
   kernel-vanilla case.)
2. On a new point release: §2 rebase (conflict ⇒ GitHub issue, touch nothing),
   §3 seeded-infra arkify run, §8 checklist mechanically, `make dist-srpm`
   smoke test, then push pinned + infra branches and fast-forward the
   consumption branch.

### What stays manual

- **Rebase conflicts** — the workflow opens an issue naming the files; run §2
  yourself.
- **New series** (X.Y → X.Y+1) — notify-only issue; do §2–§7 by hand, then bump
  `SERIES` in `targets/<target>.env`.
- **Upstream patch-source movement** (sc7280-mainline pushed new patches,
  linux-surface changed a series) — resyncing the patch stack needs judgment.

### Where results are reported

Everything reports through issues in the automation repo. A persistent
**“COPR build dashboard”** issue is kept open and edited in place every 6 hours
with per-target/per-chroot build status; a comment (→ one notification) is
added only on state transitions, and every *failed* COPR build additionally
gets its own deduplicated issue with log links. Rebase conflicts, new upstream
series, and a dead deploy key each open their own issue too — a quiet issue
tracker means everything is green.

### Rehearsing changes to the automation

`workflow_dispatch` with `dry_run: true` pushes `rehearsal/*` refs and never
touches a consumption branch; compare the rehearsal tree hash against a manual
run before trusting script changes.
