#!/usr/bin/env bash
# Assemble the worst-case renderer fixture (tools/ci/text_fixture.js) into a
# runnable page for `viewer_smoke.mjs --bundle`.
#
#   tools/ci/build_text_fixture.sh <built bundle dir> <output dir>
#
# The page is client/replay_broadcast.html spliced exactly the way it is
# served: the same three marker substitutions Dockerfile.replay-viewer makes,
# with broadcast_core.js in the BROADCAST_CORE slot (the LIVE form, which is
# what src/coins/server.nim splices at compile time) plus the fixture driver
# straight after it, so the driver can stub the page's socket before the
# page's own IIFE calls core.start(). wire_constants.js and the art come from
# the bundle that was just built, so the fixture runs against the same bytes
# the platform serves.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <built bundle dir> <output dir>" >&2
  exit 1
fi
bundle="$1"
out="$2"

test -s "${bundle}/wire_constants.js" || {
  echo "::error::${bundle}/wire_constants.js is missing; build the bundle first"
  exit 1; }

rm -rf "${out}"
mkdir -p "${out}"
cp "${bundle}/wire_constants.js" "${out}/wire_constants.js"
cp "${repo_dir}/client/chrome_common.js" "${out}/chrome_common.js"
cp "${repo_dir}/client/broadcast_core.js" "${out}/broadcast_core.js"
cp "${repo_dir}/tools/ci/text_fixture.js" "${out}/text_fixture.js"
if [[ -d "${bundle}/art" ]]; then
  cp -R "${bundle}/art" "${out}/art"
fi

sed -e 's|<!-- WIRE_CONSTANTS -->|<script src="./wire_constants.js"></script>|' \
    -e 's|<!-- CHROME_COMMON -->|<script src="./chrome_common.js"></script>|' \
    -e 's|<!-- BROADCAST_CORE -->|<script src="./broadcast_core.js"></script><script src="./text_fixture.js"></script>|' \
  "${repo_dir}/client/replay_broadcast.html" > "${out}/index.html"

grep -q 'text_fixture.js' "${out}/index.html"
grep -q 'chrome_common.js' "${out}/index.html"
grep -q 'broadcast_core.js' "${out}/index.html"
grep -q 'COINS additions to the inherited coworld-ctf chrome' "${out}/index.html"
if grep -q '<!-- CHROME_COMMON -->' "${out}/index.html"; then
  echo "::error::the CHROME_COMMON marker survived the splice"
  exit 1
fi
echo "text fixture: ${out}/index.html"
