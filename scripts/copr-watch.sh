#!/bin/bash
# copr-watch.sh — close the loop on COPR build results.
#
# The rebase workflow's smoke test proves packaging (dist-srpm), not
# compilation; a driver that stops building fails in COPR an hour after the
# workflow went green. This watcher polls the public COPR API (no credentials)
# and reports through issues:
#
#   * ONE persistent "COPR build dashboard" issue, kept open, its body edited
#     in place with a per-target status table. A comment is added only when
#     something changed since the last run (new build, state transition), so
#     success notifications happen exactly once per transition, not every tick.
#   * One issue per failed REBASE, i.e. per (target, kernel version):
#     "[target] Kernel Release vX.Y.Z failed to build". Every failed COPR
#     build belonging to that rebase lands in that same issue (first failure
#     in the body, later ones as comments, deduplicated by build id). It needs
#     manual solving and closing; a further failure of the same version
#     reopens it - the rebase is evidently not solved. A different version is
#     a different rebase and gets its own issue.
#
# Stateless: the previous state travels inside an HTML comment in the
# dashboard body.
set -euo pipefail

TARGET_DIR=$(dirname "$0")/../targets
DASH_TITLE=${DASH_TITLE:-"COPR build dashboard"}
now=$(date -u +'%Y-%m-%d %H:%M UTC')

# exact-title issue lookup via the list API - the search API's index lags by
# up to minutes and would let two quick runs double-file the same issue.
find_issue() { # $1 = title, $2 = state filter (open|all) -> "number state" or ""
    gh issue list -R "$GITHUB_REPOSITORY" --state "$2" -L 500 --json number,title,state |
        T="$1" python3 -c 'import json,os,sys
for i in json.load(sys.stdin):
    if i["title"] == os.environ["T"]:
        print(i["number"], i["state"]); break'
}

# ---- collect current state as JSON ----------------------------------------
# FAKE_STATE: test hook - inject a state JSON instead of querying COPR.
state=${FAKE_STATE:-}
[ -n "$state" ] || state=$(
for env in "$TARGET_DIR"/*.env; do
    unset TARGET COPR_PROJECT; # shellcheck disable=SC1090
    source "$env"
    COPR_PROJECT_Q="$COPR_PROJECT" TARGET_Q="$TARGET" python3 <<'PY'
import json, os, urllib.request, urllib.parse
proj = os.environ["COPR_PROJECT_Q"]          # e.g. @mobility/sc7280
owner, name = proj.split("/", 1)
q = urllib.parse.urlencode({"ownername": owner, "projectname": name,
                            "packagename": "kernel", "with_latest_build": "True"})
try:
    p = json.load(urllib.request.urlopen(
        f"https://copr.fedorainfracloud.org/api_3/package?{q}", timeout=30))
    b = (p.get("builds") or {}).get("latest")
except Exception as e:
    print(json.dumps({"target": os.environ["TARGET_Q"], "error": str(e)})); raise SystemExit
if not b:
    print(json.dumps({"target": os.environ["TARGET_Q"], "error": "no build"})); raise SystemExit
chroots = {}
for ch in b.get("chroots") or []:
    cq = urllib.parse.urlencode({"build_id": b["id"], "chrootname": ch})
    try:
        c = json.load(urllib.request.urlopen(
            f"https://copr.fedorainfracloud.org/api_3/build-chroot?{cq}", timeout=30))
        chroots[ch] = {"state": c.get("state"), "url": c.get("result_url")}
    except Exception:
        chroots[ch] = {"state": "?", "url": None}
print(json.dumps({"target": os.environ["TARGET_Q"], "build": b["id"],
                  "state": b.get("state"),
                  "version": (b.get("source_package") or {}).get("version"),
                  "project": proj, "chroots": chroots}))
PY
done | python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))'
)
echo "current state: $state"

# ---- render dashboard body -------------------------------------------------
body=$(STATE="$state" NOW="$now" python3 <<'PY'
import json, os
state = json.loads(os.environ["STATE"]); now = os.environ["NOW"]
icon = {"succeeded": "✅", "failed": "❌", "running": "🔄", "pending": "⏳",
        "starting": "⏳", "importing": "⏳", "waiting": "⏳", "canceled": "⚪"}
lines = [
    "Live status of the latest `kernel` build per COPR project. "
    "Edited in place by the `copr-watch` workflow; comments appear only on state changes. "
    "Failed builds additionally get their own issue.",
    "", "| target | version | build | state | chroots |", "|---|---|---|---|---|",
]
for t in state:
    if "error" in t:
        lines.append(f"| {t['target']} | — | — | ⚠️ {t['error']} | — |"); continue
    proj = t["project"].lstrip("@")
    burl = f"https://copr.fedorainfracloud.org/coprs/g/{proj}/build/{t['build']}/"
    chs = "<br>".join(f"{icon.get(v['state'], '❔')} `{c.replace('fedora-','f')}`"
                      for c, v in sorted(t["chroots"].items()))
    lines.append(f"| **{t['target']}** | `{t.get('version') or '?'}` "
                 f"| [{t['build']}]({burl}) | {icon.get(t['state'], '❔')} {t['state']} | {chs} |")
lines += ["", f"_Last checked: {now}_", "",
          "<!-- copr-watch-state: " + json.dumps(
              {t["target"]: {"build": t.get("build"), "state": t.get("state")}
               for t in state if "error" not in t}, sort_keys=True) + " -->"]
print("\n".join(lines))
PY
)

# ---- dashboard issue: create or update, comment on change ------------------
num=$(find_issue "$DASH_TITLE" open | cut -d' ' -f1)
new_marker=$(grep -o '<!-- copr-watch-state: .* -->' <<<"$body")
if [ -z "$num" ]; then
    echo "creating dashboard issue"
    gh issue create -R "$GITHUB_REPOSITORY" --title "$DASH_TITLE" --body "$body"
else
    old_marker=$(gh issue view "$num" -R "$GITHUB_REPOSITORY" --json body --jq .body |
                 grep -o '<!-- copr-watch-state: .* -->' || true)
    gh issue edit "$num" -R "$GITHUB_REPOSITORY" --body "$body" >/dev/null
    if [ "$old_marker" != "$new_marker" ]; then
        echo "state changed - commenting"
        STATE="$state" python3 <<'PY' | gh issue comment "$num" -R "$GITHUB_REPOSITORY" --body-file -
import json, os
state = json.loads(os.environ["STATE"])
out = []
for t in state:
    if "error" in t: out.append(f"- **{t['target']}**: ⚠️ {t['error']}"); continue
    proj = t["project"].lstrip("@")
    out.append(f"- **{t['target']}**: build [{t['build']}]"
               f"(https://copr.fedorainfracloud.org/coprs/g/{proj}/build/{t['build']}/) "
               f"`{t.get('version') or '?'}` → **{t['state']}**")
print("\n".join(out))
PY
    else
        echo "no change"
    fi
fi

# ---- one issue per failed rebase (target + version) ------------------------
STATE="$state" python3 <<'PY' > /tmp/failed.txt
import json, os
for t in json.loads(os.environ["STATE"]):
    if t.get("state") == "failed":
        bad = {c: v for c, v in t["chroots"].items() if v["state"] == "failed"}
        proj = t["project"].lstrip("@")
        detail = [f"COPR build [{t['build']}](https://copr.fedorainfracloud.org/coprs/g/{proj}/build/{t['build']}/) "
                  f"(`{t.get('version') or '?'}`) failed.", "", "Failed chroots:"]
        for c, v in sorted(bad.items()):
            log = (v["url"] or "").rstrip("/") + "/builder-live.log.gz" if v["url"] else "(no result url)"
            detail.append(f"- `{c}` — {log}")
        ver = "v" + (t.get("version") or "?").split("-")[0]
        print(json.dumps({"id": t["build"],
                          "title": f"[{t['target']}] Kernel Release {ver} failed to build",
                          "detail": "\n".join(detail)}))
PY
while read -r line; do
    title=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["title"])' "$line")
    bid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$line")
    read -r num istate <<<"$(find_issue "$title" all)"
    if [ -z "$num" ]; then
        { python3 -c 'import json,sys; print(json.loads(sys.argv[1])["detail"])' "$line"
          echo; echo "Further failed builds of this release will be added as comments."
          echo "Close this issue once the rebase builds; another failure of the same release reopens it."
          echo; echo "<!-- copr-failed-builds: [$bid] -->"; } |
            gh issue create -R "$GITHUB_REPOSITORY" --title "$title" --body-file -
        echo "opened rebase-failure issue for: $title (build $bid)"
    else
        reported=$(gh issue view "$num" -R "$GITHUB_REPOSITORY" --json body --jq .body |
                   sed -n 's/.*<!-- copr-failed-builds: \(\[[0-9, ]*\]\) -->.*/\1/p'); reported=${reported:-[]}
        if python3 -c 'import json,sys; sys.exit(0 if int(sys.argv[1]) in json.loads(sys.argv[2]) else 1)' "$bid" "$reported"; then
            continue   # this build already reported
        fi
        [ "$istate" = "CLOSED" ] && gh issue reopen "$num" -R "$GITHUB_REPOSITORY"
        python3 -c 'import json,sys; print(json.loads(sys.argv[1])["detail"])' "$line" |
            gh issue comment "$num" -R "$GITHUB_REPOSITORY" --body-file -
        newbody=$(gh issue view "$num" -R "$GITHUB_REPOSITORY" --json body --jq .body |
                  REP="$reported" BID="$bid" python3 -c '
import json,os,sys
rep = os.environ["REP"]; bid = int(os.environ["BID"])
body = sys.stdin.read(); ids = sorted(set(json.loads(rep)) | {bid})
print(body.replace("<!-- copr-failed-builds: %s -->" % rep,
                   "<!-- copr-failed-builds: %s -->" % json.dumps(ids)))')
        gh issue edit "$num" -R "$GITHUB_REPOSITORY" --body "$newbody" >/dev/null
        echo "added build $bid to rebase-failure issue #$num"
    fi
done < /tmp/failed.txt
echo "done"
