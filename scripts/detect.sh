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
TARGET_DIR=$(dirname "$0")/../targets
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
    if [ -z "$(gh issue list -R "$GITHUB_REPOSITORY" --state open --search "in:title \"$1\"" --json number --jq '.[0].number')" ]; then
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
        matrix=$(echo "$matrix" | python3 -c "
import json,sys; m=json.load(sys.stdin)
m.append({'target':'$TARGET','version':'$newN','old':'$curN'})
print(json.dumps(m))")
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
