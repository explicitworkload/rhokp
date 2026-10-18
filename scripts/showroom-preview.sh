#!/usr/bin/env bash
#
# Run the real Showroom UI locally -- the split pane, the tab bar and the
# navigation sidebar -- not just the bare Antora site.
#
# `npm run preview` serves the Antora output on its own. That is enough to
# proofread prose, but it cannot show you the things that only exist in
# Showroom: the 50/50 split, the tab bar, how the guide looks squeezed into
# half a browser window. Those come from Nookbag, the React app RHDP puts in
# front of the content, which ships as a container image.
#
# This script pulls that image, lifts the static UI out of it, drops our own
# ui-config.yml and Antora build alongside it in the layout Nookbag expects,
# and serves the lot.
#
#   scripts/showroom-preview.sh              # build, assemble, serve on 8080
#   scripts/showroom-preview.sh -p 9000      # another port
#   scripts/showroom-preview.sh -n           # skip the Antora rebuild
#   scripts/showroom-preview.sh -t v0.5      # pin a different Nookbag release
#
# The Terminal tab is replaced with Nookbag's placeholder page, because there
# is no bastion and no wetty here. Everything else is the genuine article.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
PREVIEW="${ROOT}/.preview"

PORT=8080
REBUILD=true
# Pinned deliberately. quay.io/rhpds/nookbag:latest is an OLDER build that
# reads a different config schema -- it wants `nookbag.yml` with an `antora:`
# block and ignores default_width, view_switcher and persist_url_state. v0.5
# is the line that reads ui-config.yml, which is what this repository ships.
NOOKBAG_TAG=v0.5
IMAGE_BASE=quay.io/rhpds/nookbag

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)     PORT="${2:?}";         shift 2 ;;
    -t|--tag)      NOOKBAG_TAG="${2:?}";  shift 2 ;;
    -n|--no-build) REBUILD=false;         shift ;;
    -h|--help)     sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown option: $1" ;;
  esac
done

IMAGE="${IMAGE_BASE}:${NOOKBAG_TAG}"

command -v podman >/dev/null || die "podman is needed to fetch the Nookbag UI image."
command -v python3 >/dev/null || die "python3 is needed to serve the preview."

# --- 1. the Antora site ----------------------------------------------------

if [[ "${REBUILD}" == true ]]; then
  info "Building the Antora site"
  npx antora site.yml
fi
[[ -f "${ROOT}/www/modules/index.html" ]] || \
  die "no Antora output in ./www -- run without -n, or 'npm install' first."

# --- 2. the Nookbag UI -----------------------------------------------------
#
# The image is amd64-only. We never run it, we only read static files out of
# it, so --arch avoids a pointless "platform does not match" refusal on arm64.

if [[ ! -f "${PREVIEW}/.nookbag-${NOOKBAG_TAG}" ]]; then
  info "Fetching the Nookbag UI from ${IMAGE}"
  podman image exists "${IMAGE}" || podman pull --arch amd64 -q "${IMAGE}" >/dev/null

  cid="$(podman create --arch amd64 "${IMAGE}")"
  trap 'podman rm -f "${cid}" >/dev/null 2>&1 || true' EXIT

  rm -rf "${PREVIEW}"
  mkdir -p "${PREVIEW}"
  # The UI lives in the httpd document root, not in the s2i source dir.
  podman cp "${cid}:/var/www/html/." "${PREVIEW}/"
  podman rm "${cid}" >/dev/null
  trap - EXIT

  rm -f "${PREVIEW}/.DS_Store" "${PREVIEW}"/nookbag-*.zip
  touch "${PREVIEW}/.nookbag-${NOOKBAG_TAG}"
else
  info "Reusing the Nookbag UI already in .preview"
fi

[[ -f "${PREVIEW}/index.html" ]] || die "the image did not contain a Nookbag UI at /var/www/html."

# --- 3. the layout Nookbag expects -----------------------------------------
#
# With `type: showroom` the app looks for the Antora output under ./www and
# the component under ./www/modules, which is exactly what site.yml produces.
# A symlink keeps an `npx antora site.yml` rebuild visible without re-running
# this script.

rm -rf "${PREVIEW}/www"
ln -s "${ROOT}/www" "${PREVIEW}/www"

# Point the Terminal tab at Nookbag's own placeholder: there is no wetty here,
# and an unreachable iframe renders as a dead grey pane that looks like a bug.
python3 -I - "$ROOT/ui-config.yml" "$PREVIEW/ui-config.yml" <<'PY'
import re, sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

# Deliberately textual rather than a YAML round-trip: this keeps the comments
# in ui-config.yml intact, so what you read in the preview copy still explains
# itself. Only the tab's path/port lines are swapped.
out, in_tabs = [], False
for line in text.splitlines():
    if re.match(r'^tabs:', line):
        in_tabs = True
    if in_tabs and re.match(r'^\s+(path|port):', line):
        continue
    if in_tabs and re.match(r'^\s+- name:', line):
        out.append(line)
        out.append('    url: placeholder   # local preview: no wetty here')
        continue
    out.append(line)

open(dst, 'w').write('\n'.join(out) + '\n')
print('   Terminal tab -> placeholder.html')
PY

# --- 4. serve --------------------------------------------------------------

WIDTH="$(python3 -I -c "
import re,sys
m=re.search(r'^default_width:\s*(\d+)', open('${ROOT}/ui-config.yml').read(), re.M)
print(m.group(1) if m else '?')
")"

cat <<BANNER

  Showroom preview   http://localhost:${PORT}/
  Nookbag ${NOOKBAG_TAG}         split ${WIDTH}/$((100 - WIDTH))  (override live with ?w=NN)

  The Terminal pane is a placeholder. Everything else -- the split, the tab
  bar, the sidebar, the theme CSS -- is what RHDP serves.

  Rebuild content in another shell with 'npx antora site.yml' and refresh.
  Ctrl-C to stop.

BANNER

exec python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${PREVIEW}"
