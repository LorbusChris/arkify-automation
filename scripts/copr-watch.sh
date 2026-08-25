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
#   * A separate deduplicated issue per FAILED build, with the failed chroots
#     and direct log links.
#
# Stateless: the previous state travels inside an HTML comment in the
# dashboard body.
set -euo pipefail

TARGET_DIR=$(dirname "$0")/../targets
DASH_TITLE="COPR build dashboard"
now=$(date -u +'%Y-%m-%d %H:%M UTC')

# ---- collect current state as JSON ----------------------------------------
state=$(
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
num=$(gh issue list -R "$GITHUB_REPOSITORY" --state open \
        --search "in:title \"$DASH_TITLE\"" --json number --jq '.[0].number')
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

# ---- separate issue per failed build ---------------------------------------
STATE="$state" python3 <<'PY' > /tmp/failed.txt
import json, os
for t in json.loads(os.environ["STATE"]):
    if t.get("state") == "failed":
        bad = {c: v for c, v in t["chroots"].items() if v["state"] == "failed"}
        proj = t["project"].lstrip("@")
        body = [f"COPR build [{t['build']}](https://copr.fedorainfracloud.org/coprs/g/{proj}/build/{t['build']}/) "
                f"(`{t.get('version') or '?'}`) failed.", "", "Failed chroots:"]
        for c, v in sorted(bad.items()):
            log = (v["url"] or "").rstrip("/") + "/builder-live.log.gz" if v["url"] else "(no result url)"
            body.append(f"- `{c}` — {log}")
        print(json.dumps({"title": f"[{t['target']}] COPR build {t['build']} failed",
                          "body": "\n".join(body)}))
PY
while read -r line; do
    title=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["title"])' "$line")
    exists=$(gh issue list -R "$GITHUB_REPOSITORY" --state all \
               --search "in:title \"$title\"" --json number --jq '.[0].number')
    if [ -z "$exists" ]; then
        python3 -c 'import json,sys; print(json.loads(sys.argv[1])["body"])' "$line" |
            gh issue create -R "$GITHUB_REPOSITORY" --title "$title" --body-file -
    fi
done < /tmp/failed.txt
echo "done"
