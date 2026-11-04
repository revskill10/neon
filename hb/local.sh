#!/usr/bin/env bash
# Builds and tests this fork on this machine, in Neon's build-tools image (the one CI builds images with), so a change
# is checked here and a push needs no CI run (the plan's minutes are scarce). Cargo's target directory and registry live
# in named Docker volumes, so a second run compiles only what changed.
#
#   hb/local.sh headers                 installs the Postgres headers the Rust crates build against (once)
#   hb/local.sh check <crate>...        cargo check of those crates
#   hb/local.sh test <crate>... [-- <cargo test arguments>]   cargo test of those crates
#   hb/local.sh clippy <crate>...       cargo clippy of those crates, warnings as errors
#   hb/local.sh ext                     builds Postgres 17 and the Neon extension against it (pgxn/neon)
#
# HB_LOCAL_MEMORY (default 7g) caps the container; HB_LOCAL_JOBS (default 4) caps cargo's jobs.
set -euo pipefail
cd "$(dirname "$0")/.."
tag="$(cat build-tools/Dockerfile build-tools/package.json build-tools/package-lock.json $(find build-tools/patches -type f | sort) | sha256sum | cut -c1-40)-bookworm"
image="ghcr.io/revskill10/build-tools:$tag"
here="$(pwd -W 2>/dev/null || pwd)"
# Each named volume and where it is mounted: cargo's target and registry, Postgres's build and install trees
target=/target registry=/home/nonroot/.cargo/registry pg_build=/pg-build pg_install=/pg-install
volumes=(-v "hb-neon-target:$target" -v "hb-neon-cargo-registry:$registry" -v "hb-neon-pg-build:$pg_build"
  -v "hb-neon-pg-install:$pg_install")
docker_run() { MSYS_NO_PATHCONV=1 docker run --rm "$@"; }
run() {
  # New volumes are root's; the image builds as its own user, which then owns all it writes below their roots
  docker_run -u 0 "${volumes[@]}" "$image" chown "$(docker_run "$image" id -u):$(docker_run "$image" id -g)" \
    "$target" "$registry" "$pg_build" "$pg_install"
  docker_run --init --memory "${HB_LOCAL_MEMORY:-7g}" -w /src -v "$here:/src" "${volumes[@]}" \
    -e POSTGRES_INSTALL_DIR="$pg_install" -e CARGO_TARGET_DIR="$target" \
    -e CARGO_BUILD_JOBS="${HB_LOCAL_JOBS:-4}" -e CARGO_INCREMENTAL=1 \
    "$image" bash -c "git config --global --add safe.directory '*' && $1"
}
# The crates as -p flags; anything after -- goes to cargo as it is (cargo test's own arguments, such as --no-run)
crates() {
  local out="" rest=""
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; rest="$*"; break; fi
    out="$out -p $1"; shift
  done
  printf '%s %s' "$out" "$rest"
}
command="${1:-}"; shift || true
case "$command" in
  # We run Postgres 17 only; the Rust bindings (postgres_ffi) still read every version's headers, so the others get
  # their headers only (configure and install headers, nothing compiled)
  headers) run "make -s -j${HB_LOCAL_JOBS:-4} BUILD_DIR=$pg_build POSTGRES_INSTALL_DIR=$pg_install postgres-headers" ;;
  ext)     run "make -s -j${HB_LOCAL_JOBS:-4} BUILD_DIR=$pg_build POSTGRES_INSTALL_DIR=$pg_install POSTGRES_VERSIONS=v17 NEON_CARGO_ARTIFACT_TARGET_DIR=$target/debug neon-pg-ext-v17" ;;
  check)   run "cargo check --locked $(crates "$@")" ;;
  test)    run "cargo test --locked $(crates "$@")" ;;
  clippy)  run "cargo clippy --locked $(crates "$@") -- -D warnings" ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
