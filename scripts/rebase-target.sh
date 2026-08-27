#!/bin/bash
# rebase-target.sh — rebase one arkify target onto a new kernel point release
# and re-run arkify. This is docs/arkify-sop.md §2–§3 (on the kernel repo's
# arkify-local-infra-* branches), encoded. Same-series point releases only;
# new-series bring-up is manual (SOP §7).
#
# Environment:
#   TARGET       sc7280 | surface
#   NEW_VERSION  X.Y.Z to rebase onto (tag vX.Y for Z=0, else vX.Y.Z)
#   OLD_VERSION  current X.Y.Z (from detect.sh)
#   CONSUMPTION  consumption branch (copr-sc7280 / copr-surface)
#   DRY_RUN      "true" -> push rehearsal/* refs, skip the consumption push
#   Auth: SSH deploy key for the kernel repo, configured by the workflow
#   (key file + GIT_SSH_COMMAND). Deploy keys do not expire.
#
# Exit codes: 0 ok
#             2 real patch conflict - needs a human, SOP §2
#             3 tooling failure in this automation - the patch stack is likely fine
#             1 anything else
# On 2 and 3 the detail lands in $GITHUB_WORKSPACE/conflict.txt and the kind in
# failkind.txt, so the workflow can title the issue honestly.
# Runs on Fedora only (arkify requirement).
set -euo pipefail
say() { echo "==> $*"; }

: "${TARGET:?}" "${NEW_VERSION:?}" "${OLD_VERSION:?}" "${CONSUMPTION:?}" "${RHEL_RELEASE:?}"
# precedence: environment > config.env > built-in default
_slug_override=${KERNEL_REPO_SLUG:-}
# shellcheck disable=SC1091
[ -f "$(dirname "$0")/../config.env" ] && source "$(dirname "$0")/../config.env"
KERNEL_REPO_SLUG=${_slug_override:-${KERNEL_REPO_SLUG:-LorbusChris/linux}}
KERNEL_PUSH_URL=${KERNEL_PUSH_URL:-git@github.com:$KERNEL_REPO_SLUG}
DRY_RUN=${DRY_RUN:-false}
WORKDIR=${WORKDIR:-$PWD/kwork}
CONFLICT_OUT=${GITHUB_WORKSPACE:-$PWD}/conflict.txt
FAILKIND_OUT=${GITHUB_WORKSPACE:-$PWD}/failkind.txt
RUNLOG=$(mktemp)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# tag name: vX.Y for X.Y.0, else vX.Y.Z
ver_tag() { case "$1" in *.*.0) echo "v${1%.0}";; *) echo "v$1";; esac; }
NEW_TAG=$(ver_tag "$NEW_VERSION"); OLD_TAG=$(ver_tag "$OLD_VERSION")
SERIES=${NEW_VERSION%.*}
# arkify kind: SUBLEVEL 0 -> mainline, else stable-X.Y  (SOP §3)
case "$NEW_VERSION" in *.*.0) KIND=mainline;; *) KIND=stable-$SERIES;; esac

OLD_PIN=linux-$OLD_VERSION-$TARGET-arkify
NEW_PIN=linux-$NEW_VERSION-$TARGET-arkify
OLD_INFRA=arkify-local-infra-$OLD_PIN
NEW_INFRA=arkify-local-infra-$NEW_PIN

# A full clone, deliberately: NOT --filter=blob:none.
#
# Correctness: a blobless clone makes this repo the promisor for missing
# blobs, but the release tag is fetched from git.kernel.org when the fork does
# not carry it yet, so the rebase asks the promisor for objects it has never
# seen and dies with "upload-pack: not our ref". That killed the surface job.
#
# Speed: counter-intuitively the full clone is much faster end to end. The
# blobless clone itself is quick (~35s, vs minutes here), but working inside a
# partial clone made the later `git fetch arkify` pathological - 74 minutes
# between two adjacent steps. Measured on the 7.2.1 rehearsal, the entire
# rebase step is 10m29s (sc7280) / 15m21s (surface) with a full clone, against
# 78+ minutes to merely reach arkify before. Do not "optimise" this back
# without re-measuring; if you must, multiple promisor remotes
# (remote.<name>.promisor=true for stable and arkify) is the shape that works.
say "clone (full history and blobs)"
git clone "$KERNEL_PUSH_URL" "$WORKDIR"
cd "$WORKDIR"
git config user.name  "arkify-automation"
git config user.email "arkify-automation@noreply.github.com"
git remote add stable https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
git fetch --quiet origin "refs/tags/$NEW_TAG:refs/tags/$NEW_TAG" || true
git rev-parse -q --verify "$NEW_TAG" >/dev/null || {
    say "tag $NEW_TAG not in the kernel repo yet - fetching from stable"
    git fetch --quiet stable "refs/tags/$NEW_TAG:refs/tags/$NEW_TAG"
}

say "sanity: $OLD_PIN tip must be the single 'bulk import ark-infra' commit"
tip_subject=$(git log -1 --format=%s "origin/$OLD_PIN")
[ "$tip_subject" = "bulk import ark-infra" ] || { echo "unexpected tip on $OLD_PIN: $tip_subject"; exit 1; }

old_patches=$(git rev-list --count "$OLD_TAG..origin/$OLD_PIN^")
old_seps=$(git log --oneline "$OLD_TAG..origin/$OLD_PIN^" --grep='^-------------' | wc -l)
say "old stack: $old_patches patches ($old_seps separators) on $OLD_TAG"

say "SOP §2: rebase the patch stack onto $NEW_TAG (no --empty=drop)"
git checkout -q -b "$NEW_PIN" "origin/$OLD_PIN^"
if ! git rebase --onto "$NEW_TAG" "$OLD_TAG" >"$RUNLOG" 2>&1; then
    # Distinguish a real patch conflict (needs a human, SOP §2) from a tooling
    # failure (needs a fix here). Reporting every non-zero rebase exit as a
    # "conflict" once sent two issues blaming a rebase that was actually clean.
    conflicted=$(git diff --name-only --diff-filter=U)
    if [ -n "$conflicted" ]; then
        {
            echo "Rebase of $TARGET onto $NEW_TAG stopped on real patch conflicts."
            echo; echo "Conflicting files:"; echo "$conflicted" | sed 's/^/  - /'
            echo; echo "Run docs/arkify-sop.md §2 manually for this release."
        } | tee "$CONFLICT_OUT"
        echo conflict > "$FAILKIND_OUT"
        git rebase --abort
        exit 2
    fi
    {
        echo "Rebase of $TARGET onto $NEW_TAG failed WITHOUT any conflicting file."
        echo "This is a tooling failure in arkify-automation, not a patch conflict -"
        echo "the patch stack itself may be perfectly fine. git said:"
        echo; sed 's/^/  /' "$RUNLOG" | tail -25
    } | tee "$CONFLICT_OUT"
    echo tooling > "$FAILKIND_OUT"
    git rebase --abort 2>/dev/null || true
    exit 3
fi
cat "$RUNLOG"

new_patches=$(git rev-list --count "$NEW_TAG..HEAD")
new_seps=$(git log --oneline "$NEW_TAG..HEAD" --grep='^-------------' | wc -l)
dropped=$((old_patches - new_patches))
say "new stack: $new_patches patches ($dropped auto-dropped as already upstream)"
[ "$new_seps" -eq "$old_seps" ] || { echo "separator commits lost ($old_seps -> $new_seps)"; exit 1; }
[ "$dropped" -ge 0 ] && [ "$dropped" -le 20 ] || { echo "implausible drop count $dropped"; exit 1; }
[ "$(git describe --tags --abbrev=0 HEAD)" = "$NEW_TAG" ] || { echo "base tag mismatch"; exit 1; }

say "SOP §3: seed infra branch from same-target predecessor, fetch arkify refs"
git branch "$NEW_INFRA" "origin/$OLD_INFRA"
git remote add arkify https://gitlab.com/knurd42/linux.git/
for b in arkify-arkify "arkify-fixes-$KIND" "arkify-infra-$KIND" "arkify-upstream-$KIND"; do
    git remote set-branches --add arkify "$b"
done
# all infra kinds, not just $KIND: when a series jumps mainline -> stable-X.Y,
# arkify's infra rebase still needs the *previous* base tag (e.g. a mainline
# one) to find its _previous_base. Still a narrow glob, unlike --tags.
git fetch --quiet arkify "refs/tags/arkify-infra-*:refs/tags/arkify-infra-*" \
                         "refs/tags/arkify-fixes-$KIND-*:refs/tags/arkify-fixes-$KIND-*"
git fetch --quiet arkify

# Drop the legacy settings commit before arkify rebases the infra branch.
# Replaying it across an ark-infra era change is what broke 7.2.1: the whole
# conflict was a comment next to RELEASED_KERNEL, whose value was identical on
# both sides. The settings are regenerated below from apply-infra-settings.sh,
# so nothing is lost - config and docs commits still ride along as patches,
# and they touch files ark does not.
legacy=$(git log --format='%H %s' "$NEW_INFRA" --grep='^downstream: ark-infra customisation' -1 | cut -d' ' -f1)
if [ -n "$legacy" ]; then
    say "dropping legacy settings commit ${legacy:0:12} (regenerated after import)"
    git checkout -q "$NEW_INFRA"
    git rebase --quiet --onto "$legacy^" "$legacy" "$NEW_INFRA" || {
        echo "could not drop the legacy settings commit"; git rebase --abort 2>/dev/null || true; exit 3; }
    git checkout -q "$NEW_PIN"
fi

run_arkify() { # arkify runs under set -e; capture failure as a tooling fault
    if ! curl --silent 'https://gitlab.com/knurd42/linux/-/raw/arkify-arkify/arkify' | bash >"$RUNLOG" 2>&1; then
        cat "$RUNLOG"
        {
            echo "arkify failed for $TARGET on $NEW_TAG. This is an arkify/ark-infra"
            echo "problem, not a conflict in our kernel patch stack - that rebased"
            echo "cleanly ($new_patches patches). arkify said:"
            echo; sed 's/^/  /' "$RUNLOG" | tail -30
        } | tee "$CONFLICT_OUT"
        echo tooling > "$FAILKIND_OUT"
        git rebase --abort 2>/dev/null || true
        exit 3
    fi
    cat "$RUNLOG"
}

say "run arkify (rebases the infra branch onto the new ark-infra, then imports)"
run_arkify

say "regenerate downstream settings on the infra branch (idempotent, no patch to conflict)"
git checkout -q "$NEW_INFRA"
TARGET="$TARGET" RHEL_RELEASE="$RHEL_RELEASE" bash "$SCRIPT_DIR/apply-infra-settings.sh"
if ! git diff --quiet -- redhat/Makefile.variables Makefile.rhelver .copr/Makefile; then
    git add -f redhat/Makefile.variables Makefile.rhelver .copr/Makefile
    git commit -q -s -m 'downstream: ark-infra customisation for COPR builds

Regenerated by arkify-automation (scripts/apply-infra-settings.sh) rather
than replayed as a patch, so an ark-infra era change cannot conflict.'
    say "settings commit regenerated"
else
    say "settings already correct on the new base"
fi
git checkout -q "$NEW_PIN"

say "re-run arkify to import the regenerated settings"
run_arkify

say "squash to a single import commit if two accumulated"
imports=$(git log --format=%s "$NEW_TAG..HEAD" | grep -cx 'bulk import ark-infra')
if [ "$imports" -eq 2 ]; then
    tree_before=$(git rev-parse 'HEAD^{tree}')
    git reset -q --soft HEAD~2
    git commit -q -s -m 'bulk import ark-infra'
    [ "$(git rev-parse 'HEAD^{tree}')" = "$tree_before" ] || { echo "squash changed the tree"; exit 1; }
elif [ "$imports" -ne 1 ]; then
    echo "expected 1-2 import commits, found $imports"; exit 1
fi

say "SOP §8 checklist: imported settings"
git show HEAD:redhat/Makefile.variables | grep -q '^override UPSTREAM_BRANCH = \$(MARKER)$' || { echo "UPSTREAM_BRANCH override missing"; exit 1; }
git show HEAD:redhat/Makefile.variables | grep -q '^RELEASED_KERNEL:=1$' || { echo "RELEASED_KERNEL pin missing"; exit 1; }
localver=$(git show HEAD:redhat/Makefile.variables | sed -n 's/^DISTLOCALVERSION ?= //p')
rhrel=$(git show HEAD:Makefile.rhelver | sed -n 's/^RHEL_RELEASE = //p')
[ "$localver" = ".$TARGET" ] || { echo "DISTLOCALVERSION is '$localver', expected .$TARGET"; exit 1; }
infra_tag=$(git describe --tags --abbrev=0 "$NEW_INFRA")
case "$infra_tag" in arkify-infra-$KIND-*) ;; *) echo "infra branch on wrong kind: $infra_tag"; exit 1;; esac

say "smoke test: make dist-srpm"
make NO_CONFIGCHECKS=1 DIST=".fc$(rpm -E %fedora)" UPSTREAMBUILD_GIT_ONLY=0 dist-srpm >/dev/null
srpm=$(ls redhat/rpm/SRPMS/kernel-"$NEW_VERSION"-"$rhrel""$localver".*.src.rpm)
say "built $srpm"
# dist-srpm only writes untracked files under redhat/ - clean them, keep tracked
git clean -fdq
if git status --porcelain | grep -q .; then echo "tree dirty after cleanup"; exit 1; fi

if [ "$DRY_RUN" = "true" ]; then
    say "dry run: pushing rehearsal refs only"
    git push -f origin "refs/heads/$NEW_PIN:refs/heads/rehearsal/$NEW_PIN" \
                       "refs/heads/$NEW_INFRA:refs/heads/rehearsal/$NEW_INFRA"
    echo "rehearsal tree: $(git rev-parse "$NEW_PIN^{tree}")"
else
    say "ship: tag + mirror first - COPR's MARKER resolution needs $NEW_TAG in the fork"
    # The release tag MUST reach the fork before the consumption push: COPR's
    # clone resolves 'override UPSTREAM_BRANCH = $(MARKER)' against it. Also
    # refresh the linux-X.Y.y upstream mirror branch while we are here so the
    # fork's stable-series mirror does not rot (best effort - the branch does
    # not exist upstream until X.Y.1).
    git push origin "refs/tags/$NEW_TAG:refs/tags/$NEW_TAG"
    if git fetch --quiet stable "refs/heads/linux-$SERIES.y:refs/remotes/stable/linux-$SERIES.y" 2>/dev/null; then
        git push origin "refs/remotes/stable/linux-$SERIES.y:refs/heads/linux-$SERIES.y" ||
            echo "WARNING: mirror refresh of linux-$SERIES.y failed (diverged?); continuing"
    fi
    # Idempotent re-run: if this release was already published (a previous run
    # got this far and then failed later), keep the published commits rather
    # than force-pushing freshly rebased ones with the same trees but new
    # SHAs - the consumption branch should point at history people may already
    # have fetched.
    ship_ref=refs/heads/$NEW_PIN
    published=$(git ls-remote origin "refs/heads/$NEW_PIN" | cut -f1)
    if [ -n "$published" ]; then
        git fetch --quiet origin "refs/heads/$NEW_PIN:refs/remotes/origin/$NEW_PIN" || true
        if [ "$(git rev-parse "origin/$NEW_PIN^{tree}")" = "$(git rev-parse "$NEW_PIN^{tree}")" ]; then
            say "$NEW_PIN already published with an identical tree - reusing it"
            ship_ref=refs/remotes/origin/$NEW_PIN
        else
            echo "$NEW_PIN already exists on origin with a DIFFERENT tree - refusing to overwrite"
            echo "published $published, local $(git rev-parse "$NEW_PIN")"
            echo tooling > "$FAILKIND_OUT"; exit 3
        fi
    else
        say "ship: pinned + infra branches"
        git push origin "refs/heads/$NEW_PIN:refs/heads/$NEW_PIN" \
                        "refs/heads/$NEW_INFRA:refs/heads/$NEW_INFRA"
    fi

    # The consumption branch is a POINTER to the current release, not a history:
    # each release is a fresh rebase, so its commits are never descendants of
    # the previous release's. A plain push is therefore always rejected as
    # non-fast-forward from the second release onward - which is exactly how
    # the 7.2.1 ship failed. --force-with-lease still refuses if someone moved
    # the branch since our clone.
    say "ship: consumption branch $CONSUMPTION"
    git push --force-with-lease="refs/heads/$CONSUMPTION" \
        origin "$ship_ref:refs/heads/$CONSUMPTION"

    # Trigger the build explicitly via COPR's *custom* webhook.
    #
    # The GitHub webhook cannot do this for us: COPR decides which packages a
    # push affects with commits_belong_to_package(), which iterates the
    # payload's commit list - and GitHub sends "commits": [] for a force-push
    # whose new head is not a descendant of the old one. Every release here is
    # a fresh rebase, so every consumption push is exactly that shape: COPR
    # answers 200 and builds nothing. The custom webhook has no commit
    # matching; it just rebuilds the named package from its committish, which
    # we have just moved. Verified: 7.2.1 builds 10912398 / 10912399.
    if [ -n "${COPR_WEBHOOK:-}" ]; then
        say "triggering the COPR build (custom webhook)"
        code=$(curl -sS -X POST -o /tmp/copr-trigger.out -w '%{http_code}' "$COPR_WEBHOOK") || true
        if [ "$code" = "200" ]; then
            say "COPR build queued: $(cat /tmp/copr-trigger.out)"
        else
            echo "COPR custom webhook returned HTTP $code:"; head -c 400 /tmp/copr-trigger.out
            echo; echo "The branches are pushed and correct - only the build trigger failed."
            echo tooling > "$FAILKIND_OUT"; exit 3
        fi
    else
        echo "WARNING: COPR_WEBHOOK unset - branches pushed but no build triggered."
        echo "Trigger manually: copr-cli build-package $COPR_PROJECT --name kernel"
    fi
fi
say "done: $NEW_PIN ($new_patches patches + import), NVR kernel-$NEW_VERSION-$rhrel$localver"
