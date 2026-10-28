#!/usr/bin/env bash
# Build librats from source and vendor the result into vendor/librats/.
#
# Nothing from librats is committed: vendor/librats/ is generated, gitignored,
# and (re)created here. Run it once after a clone, before `zig build`; rerun it
# to bump the pin.
#
# The source tarball has no .git, so librats' CMake would fall back to the
# hardcoded 1.0.0.0 and `rats_version()` would lie about the tag it was cut
# from. -DRATS_VERSION_OVERRIDE below is the knob the project provides for
# tarball builds and makes the linked library report the real version.
set -euo pipefail

LIBRATS_VERSION="3.0.3"
URL="https://github.com/librats/librats/archive/refs/tags/${LIBRATS_VERSION}.tar.gz"
SHA256="99ad89281a4fe85bc9fcf70b1d0842aa69d55361cf7c509e1acd3b0a0f8b5ba6"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor_dir="$repo_root/vendor/librats"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for tool in cmake g++ make curl tar; do
    command -v "$tool" >/dev/null || {
        echo "$tool is required to build librats from source" >&2
        exit 1
    }
done

echo "Fetching $URL"
curl -fsSL -o "$tmp_dir/librats.tar.gz" "$URL"

actual_sha="$(sha256sum "$tmp_dir/librats.tar.gz" | awk '{print $1}')"
if [ "$actual_sha" != "$SHA256" ]; then
    echo "sha256 mismatch: expected $SHA256, got $actual_sha" >&2
    exit 1
fi

tar -xzf "$tmp_dir/librats.tar.gz" -C "$tmp_dir"
src_dir="$tmp_dir/librats-${LIBRATS_VERSION}"

# Tests, the reference client and the examples are not part of the vendored
# library. Static only: the binary must not need librats.so at runtime.
cmake -S "$src_dir" -B "$tmp_dir/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DRATS_VERSION_OVERRIDE="$LIBRATS_VERSION" \
    -DRATS_BUILD_TESTS=OFF \
    -DRATS_BUILD_CLIENT=OFF \
    -DRATS_BUILD_EXAMPLES=OFF \
    -DRATS_STATIC_LIBRARY=ON \
    -DRATS_SHARED_LIBRARY=OFF >/dev/null

cmake --build "$tmp_dir/build" -j"$(nproc)" >/dev/null

# `cmake --install` is what puts the generated librats/util/version.h (and
# features.h) beside the public headers; the release archive ships neither.
cmake --install "$tmp_dir/build" --prefix "$tmp_dir/prefix" >/dev/null

# Replace any earlier unpack rather than merging into it, so a version bump
# cannot leave stale headers behind.
rm -rf "$vendor_dir"
mkdir -p "$vendor_dir"
cp -r "$tmp_dir/prefix/include" "$vendor_dir/include"
cp "$tmp_dir/prefix/lib/librats.a" "$vendor_dir/librats.a"

echo "Vendored librats $LIBRATS_VERSION into $vendor_dir"
