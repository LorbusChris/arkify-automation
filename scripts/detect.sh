#!/bin/bash
# detect.sh — figure out which arkify targets need a rebase, statelessly.
#
# State lives in git: the current version of a target is the highest X.Y.Z
# among refs/heads/linux-X.Y.Z-<target>-arkify on the kernel repo. A rebase is
# due when kernel.org lists a newer point release in the target's series.
#
# Output (to $GITHUB_OUTPUT if set, else stdout):
#   matrix=<JSON list of {target, version} to rebase>
#
# Notify-only checks (new upstream series) open deduplicated issues in this
# repo via gh; they never trigger a rebase — new-series bring-up is manual,
# see docs/arkify-sop.md §7 in the kernel repo's arkify-local-infra-* branches.
set -euo pipefail

# precedence: environment > config.env > built-in default
_slug_override=${KERNEL_REPO_SLUG:-}
# shellcheck disable=SC1091
[ -f "$(dirname "$0")/../config.env" ] && source "$(dirname "$0")/../config.env"
KERNEL_REPO_SLUG=${_slug_override:-${KERNEL_REPO_SLUG:-LorbusChris/linux}}
KERNEL_REPO=${KERNEL_REPO:-https://github.com/$KERNEL_REPO_SLUG}
TARGET_DIR=${TARGET_DIR:-$(dirname "$0")/../targets}
ARKIFY_REMOTE=${ARKIFY_REMOTE:-https://gitlab.com/knurd42/linux.git/}
FORCE_TARGET=${FORCE_TARGET:-}   # workflow_dispatch override
FORCE_VERSION=${FORCE_VERSION:-} # workflow_dispatch override

releases_json=$(curl -sf --retry 3 https://www.kernel.org/releases.json)

# highest released version in a series, from kernel.org (mainline covers the
# X.Y.0 case where the tag is vX.Y and moniker is still "mainline")
latest_in_series() { # $1 = X.Y
    RELEASES="$releases_json" SERIES_Q="$1" python3 <<'PY'
import json, os
series = os.environ["SERIES_Q"]
d = json.loads(os.environ["RELEASES"])
best = None
for r in d["releases"]:
    if r["moniker"] not in ("stable", "longterm", "mainline"):
        continue
    v = r["version"]
    if v == series or v.startswith(series + "."):
        try:
            parts = [int(x) for x in (v + ".0").split(".")[:3]]
        except ValueError:
            continue  # skip -rc style versions
        if best is None or parts > best:
            best = parts
print("%d.%d.%d" % tuple(best) if best else "")
PY
}

# highest existing pinned-branch version for a target
current_version() { # $1 = target
    git ls-remote --heads "$KERNEL_REPO" "refs/heads/linux-*-$1-arkify" |
        sed -n 's|.*refs/heads/linux-\([0-9.]*\)-'"$1"'-arkify|\1|p' |
        sort -V | tail -1
}

open_issue_once() { # $1 = title, $2 = body
    [ -n "${GITHUB_REPOSITORY:-}" ] || { echo "NOTIFY: $1"; return; }
    # exact-title match via the list API - the search API's index lags
    local existing
    existing=$(gh issue list -R "$GITHUB_REPOSITORY" --state open -L 500 --json title |
               T="$1" python3 -c 'import json,os,sys
print(sum(1 for i in json.load(sys.stdin) if i["title"] == os.environ["T"]))')
    if [ "$existing" = "0" ]; then
        gh issue create -R "$GITHUB_REPOSITORY" --title "$1" --body "$2"
    fi
}

matrix="[]"
for env in "$TARGET_DIR"/*.env; do
    # shellcheck disable=SC1090
    unset TARGET SERIES CONSUMPTION NOTIFY_REMOTE NOTIFY_REF_PREFIX NOTIFY_PATCHDIR
    source "$env"
    [ -n "$FORCE_TARGET" ] && [ "$FORCE_TARGET" != "all" ] && [ "$FORCE_TARGET" != "$TARGET" ] && continue

    cur=$(current_version "$TARGET")
    if [ -n "$FORCE_VERSION" ]; then
        new=$FORCE_VERSION
    else
        new=$(latest_in_series "$SERIES")
    fi
    # normalize X.Y -> X.Y.0 for comparison
    curN=$(echo "${cur:-0}" | awk -F. '{printf "%d.%d.%d",$1,$2,$3}')
    newN=$(echo "${new:-0}" | awk -F. '{printf "%d.%d.%d",$1,$2,$3}')
    echo "$TARGET: current=$curN latest=$newN"
    if [ -n "$new" ] && [ "$newN" != "$curN" ] && \
       [ "$(printf '%s\n%s\n' "$curN" "$newN" | sort -V | tail -1)" = "$newN" ]; then
        # ---- ark-infra readiness gate ----
        # A stable point release (Z>=1) is built with arkify's stable-X.Y
        # infrastructure, which knurd42 derives from Fedora's kernel-ark.
        # Until arkify-infra-stable-X.Y exists there, building would rush
        # ahead of what the Fedora ark infra supports (arkify would fall back
        # to mainline infra and the rebase job's kind check would fail late).
        # Wait instead: notify once, skip, and let the next cron proceed the
        # day the branch appears. X.Y.0 series jumps are manual (SOP §7) and
        # use mainline infra, which always exists - no gate needed there.
        gate_wait=""
        case "$newN" in
        *.*.0) ;;
        *)  ser=${newN%.*}
            if ! git ls-remote --heads "$ARKIFY_REMOTE" "refs/heads/arkify-infra-stable-$ser" | grep -q .; then
                gate_wait=1
                open_issue_once \
                    "[$TARGET] waiting for arkify-infra-stable-$ser before building v$newN" \
                    "kernel.org has v$newN, but knurd42's arkify-infra-stable-$ser branch does not exist yet, so the Fedora ark infrastructure is not ready for this series. The rebase is on hold and will start automatically on a later run once the branch appears - no action needed. Close this once the build lands."
                echo "$TARGET: v$newN gated - arkify-infra-stable-$ser not available yet"
            fi
            ;;
        esac
        if [ -z "$gate_wait" ]; then
            matrix=$(echo "$matrix" | python3 -c "
import json,sys; m=json.load(sys.stdin)
m.append({'target':'$TARGET','version':'$newN','old':'$curN'})
print(json.dumps(m))")
        fi
    fi

    # ---- notify-only: new upstream series ----
    next_minor=$(echo "$SERIES" | awk -F. '{print $1"."($2+1)}')
    next_major=$(echo "$SERIES" | awk -F. '{print ($1+1)".0"}')
    for s in "$next_minor" "$next_major"; do
        found=""
        if [ -n "${NOTIFY_REF_PREFIX:-}" ]; then
            git ls-remote --heads "$NOTIFY_REMOTE" "refs/heads/${NOTIFY_REF_PREFIX}${s}.y" | grep -q . && found=branch
        elif [ -n "${NOTIFY_PATCHDIR:-}" ]; then
            repo_path=${NOTIFY_REMOTE#https://github.com/}
            gh api "repos/$repo_path/contents/$NOTIFY_PATCHDIR/$s" --jq '.[0].path' >/dev/null 2>&1 && found=patchdir
        fi
        if [ -n "$found" ]; then
            open_issue_once \
                "[$TARGET] new upstream series $s available" \
                "The $TARGET patch source ($NOTIFY_REMOTE) now carries a $s series ($found). New-series bring-up is manual: see docs/arkify-sop.md §7 on the kernel repo's arkify-local-infra-* branches. When done, bump SERIES in targets/$TARGET.env."
        fi
    done
done

echo "matrix=$matrix" | tee -a "${GITHUB_OUTPUT:-/dev/stdout}" >/dev/null
echo "work: $matrix"
