#!/bin/bash
# apply-infra-settings.sh — enforce our downstream packaging settings on the
# ark infrastructure, idempotently, in the current working tree.
#
# These settings used to live as a commit ("downstream: ark-infra customisation
# for COPR builds") that arkify replayed onto each new ark-infra base. That is
# the wrong shape: they are a desired END STATE, not a delta, so the patch
# conflicted whenever the surrounding ark text moved. Going 7.2.0 -> 7.2.1 it
# did exactly that, and the entire conflict was a comment block sitting next to
# RELEASED_KERNEL - the value was identical on both sides. See issues #17/#18.
#
# Applying the state instead means an era change (mainline -> stable-X.Y) can
# never conflict. Running this twice is a no-op.
#
# Environment: TARGET (sc7280|surface), RHEL_RELEASE (e.g. 1001)
set -euo pipefail
: "${TARGET:?}" "${RHEL_RELEASE:?}"

MV=redhat/Makefile.variables
RV=Makefile.rhelver
CM=.copr/Makefile
for f in "$MV" "$RV" "$CM"; do
    [ -f "$f" ] || { echo "apply-infra-settings: $f missing - not an arkified tree?" >&2; exit 1; }
done

# --- redhat/Makefile.variables ---------------------------------------------
# Deliberately no explanatory comments in the file: a comment adjacent to a
# value ark also edits is precisely what conflicted before. Rationale lives
# here and in docs/arkify-sop.md instead.

# We always build from a released tag. stable-X.Y ark-infra ships 1, mainline
# ships 0, so this cannot be left to the base.
sed -i 's/^RELEASED_KERNEL[[:space:]]*:\?=.*/RELEASED_KERNEL:=1/' "$MV"

# No Patchlist.changelog, and version the rpm from the upstream tag.
sed -i 's/^PATCHLIST_URL[[:space:]]*?\?=.*/PATCHLIST_URL ?= none/' "$MV"
sed -i 's/^\([[:space:]]*\)VERSION_ON_UPSTREAM[[:space:]]*?\?=.*/\1VERSION_ON_UPSTREAM ?= 1/' "$MV"

# DISTLOCALVERSION: arkify seeds this from $(whoami) on a fresh branch.
if grep -q '^DISTLOCALVERSION' "$MV"; then
    sed -i "s/^DISTLOCALVERSION[[:space:]]*?\?=.*/DISTLOCALVERSION ?= .$TARGET/" "$MV"
else
    printf '\nDISTLOCALVERSION ?= .%s\n' "$TARGET" >> "$MV"
fi

# arkify force-seds "UPSTREAM_BRANCH ?=" to a local-only branch on every
# import; that branch does not exist in COPR's clone, so redhat/Makefile
# errors with "Missing an ... branch". An `override` line is not matched by
# arkify's ^UPSTREAM_BRANCH-anchored sed, and $(MARKER) is the upstream
# release tag, computed before UPSTREAM is resolved. Appended at EOF, where
# ark does not edit, so it stays conflict-free across eras.
if ! grep -q '^override UPSTREAM_BRANCH' "$MV"; then
    printf '\noverride UPSTREAM_BRANCH = $(MARKER)\n' >> "$MV"
fi

# --- Makefile.rhelver -------------------------------------------------------
sed -i "s/^RHEL_RELEASE[[:space:]]*=.*/RHEL_RELEASE = $RHEL_RELEASE/" "$RV"

# --- .copr/Makefile ---------------------------------------------------------
sed -i \
  -e 's|git config user.email .*|git config user.email "copr@build"|' \
  -e 's|git config user.name .*|git config user.name "COPR Build"|' \
  "$CM"
# Guarded, and requires at least one digit: an unguarded DIST=\.fc[0-9]* also
# matches "DIST=.fc" *inside* the already-substituted text (zero digits), so
# re-running appended a second $(shell ...) every time.
grep -qF 'DIST=.fc$(shell rpm -E %fedora)' "$CM" ||
    sed -i 's|DIST=\.fc[0-9][0-9]*|DIST=.fc$(shell rpm -E %fedora)|' "$CM"

# --- verify what we just claimed -------------------------------------------
fail=0
check() { grep -q "$1" "$2" || { echo "apply-infra-settings: expected /$1/ in $2" >&2; fail=1; }; }
check '^RELEASED_KERNEL:=1$'                  "$MV"
check '^PATCHLIST_URL ?= none$'               "$MV"
check "^DISTLOCALVERSION ?= \.$TARGET\$"      "$MV"
check '^override UPSTREAM_BRANCH = \$(MARKER)$' "$MV"
check "^RHEL_RELEASE = $RHEL_RELEASE\$"       "$RV"
check 'rpm -E %fedora'                        "$CM"
# exactly one expansion - catches the repeated-append class of bug
[ "$(grep -o 'shell rpm -E %fedora' "$CM" | wc -l)" = 1 ] ||
    { echo "apply-infra-settings: DIST expansion is not exactly once in $CM" >&2; fail=1; }
grep -q 'VERSION_ON_UPSTREAM ?= 0' "$MV" && { echo "apply-infra-settings: VERSION_ON_UPSTREAM still 0" >&2; fail=1; }
[ "$fail" = 0 ] || exit 1
echo "apply-infra-settings: settings enforced for $TARGET (RHEL_RELEASE=$RHEL_RELEASE)"
