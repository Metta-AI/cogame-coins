#!/usr/bin/env bash
# Coworld replay-viewer build hook: invoked by `coworld build` with one
# argument, the absolute path of the static bundle directory to produce
# (<manifest-dir>/static-replay-viewer, which must end up containing
# index.html). `coworld build` refuses to package a source replay-viewer
# bundle unless this file is os.X_OK, so it ships mode 100755.
#
# coworld-ctf's script, kept, with four edits:
#   1. image_tag           -> cogame-coins-replay-viewer-build:$$
#   2. the `docker cp` source path -> /workspace/coins/replay-viewer/dist/.
#   3. the ecos fix: `mkdir -p "$(dirname "${requested_output}")"` BEFORE the
#      containment check (paintbot's hook resolves its output path by cd-ing
#      into the parent, which does not exist yet on a fresh CI checkout, so
#      the hook exits 1 before it ever builds).
#   4. the repo-containment test is relaxed to a symlink test: `coworld build`
#      is free to hand a manifest directory outside the repo, and rejecting
#      that would fail phase 40 rather than CI.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

requested_output="$1"

if [[ "${requested_output}" != /* || "$(basename "${requested_output}")" != "static-replay-viewer" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

mkdir -p "$(dirname "${requested_output}")"
output_parent="$(cd "$(dirname "${requested_output}")" && pwd -P)"
output_dir="${output_parent}/static-replay-viewer"
if [[ -L "${output_dir}" ]]; then
  echo "unsafe bundle output (symlink): ${requested_output}" >&2
  exit 1
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"

image_tag="cogame-coins-replay-viewer-build:$$"
container_id=""
cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null 2>&1 || true
  fi
  docker image rm "${image_tag}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_args=(
  --platform linux/amd64
  --file "${repo_dir}/Dockerfile.replay-viewer"
  --target replay-viewer-builder
  --tag "${image_tag}"
  "${repo_dir}"
)
if docker buildx version >/dev/null 2>&1; then
  docker buildx build --load "${build_args[@]}"
else
  # Docker Desktop installations without the buildx plugin still honor the
  # explicit amd64 platform through their Linux VM. CI installs Buildx above.
  docker build "${build_args[@]}"
fi
container_id="$(docker create --platform linux/amd64 "${image_tag}")"
docker cp "${container_id}:/workspace/coins/replay-viewer/dist/." "${output_dir}"

test -s "${output_dir}/index.html"
test -s "${output_dir}/coins_replay.wasm"
test -s "${output_dir}/static_replay.js"
grep -q 'coworld-replay' "${output_dir}/static_replay.js"
echo "coins replay viewer bundle: ${output_dir}"
