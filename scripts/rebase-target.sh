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
# Exit codes: 0 ok, 2 rebase conflict (details in $GITHUB_WORKSPACE/conflict.txt),
#             1 anything else. Runs on Fedora only (arkify requirement).
set -euo pipefail
say() { echo "==> $*"; }

: "${TARGET:?}" "${NEW_VERSION:?}" "${OLD_VERSION:?}" "${CONSUMPTION:?}"
# precedence: environment > config.env > built-in default
_slug_override=${KERNEL_REPO_SLUG:-}
# shellcheck disable=SC1091
[ -f "$(dirname "$0")/../config.env" ] && source "$(dirname "$0")/../config.env"
KERNEL_REPO_SLUG=${_slug_override:-${KERNEL_REPO_SLUG:-LorbusChris/linux}}
KERNEL_PUSH_URL=${KERNEL_PUSH_URL:-git@github.com:$KERNEL_REPO_SLUG}
DRY_RUN=${DRY_RUN:-false}
WORKDIR=${WORKDIR:-$PWD/kwork}
CONFLICT_OUT=${GITHUB_WORKSPACE:-$PWD}/conflict.txt

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

say "clone (blobless, full history)"
git clone --filter=blob:none "$KERNEL_PUSH_URL" "$WORKDIR"
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
if ! git rebase --quiet --onto "$NEW_TAG" "$OLD_TAG"; then
    {
        echo "Rebase of $TARGET onto $NEW_TAG stopped on conflicts:"
        echo; git status --short | grep -E '^(UU|AA|DD|AU|UA|DU|UD)' || git status --short
        echo; echo "Run docs/arkify-sop.md §2 manually for this release."
    } | tee "$CONFLICT_OUT"
    git rebase --abort
    exit 2
fi

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

say "run arkify"
curl --silent 'https://gitlab.com/knurd42/linux/-/raw/arkify-arkify/arkify' | bash

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
    say "ship: pinned + infra branches, then the consumption branch (triggers COPR)"
    git push origin "refs/heads/$NEW_PIN:refs/heads/$NEW_PIN" \
                    "refs/heads/$NEW_INFRA:refs/heads/$NEW_INFRA"
    git push origin "refs/heads/$NEW_PIN:refs/heads/$CONSUMPTION"
fi
say "done: $NEW_PIN ($new_patches patches + import), NVR kernel-$NEW_VERSION-$rhrel$localver"
