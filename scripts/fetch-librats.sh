#!/usr/bin/env bash
# Build librats from source for each target and vendor the result into
# vendor/librats/<arch>-<os>-<abi>/ (include/ + librats.a).
#
# Nothing from librats is committed: vendor/ is generated, gitignored, and
# (re)created here. Run it once after a clone, before `zig build`; rerun it to
# bump the pin. Pass targets to build a subset:
#
#     bash scripts/fetch-librats.sh aarch64-linux-gnu
#
# The C++ compiler is Zig's own (`zig c++ -target <triple>`), not a cross-GCC:
# it needs no root and emits objects against Zig's bundled libc++, which is also
# what links the final binary. A GCC-built archive pulls in the system
# libstdc++/__cxx11 ABI and cannot be cross-linked.
#
# The source tarball has no .git, so librats' CMake would fall back to the
# hardcoded 1.0.0.0 and `rats_version()` would lie about the tag it was cut
# from. -DRATS_VERSION_OVERRIDE below is the knob the project provides for
# tarball builds and makes the linked library report the real version.
set -euo pipefail

LIBRATS_VERSION="3.0.3"
URL="https://github.com/librats/librats/archive/refs/tags/${LIBRATS_VERSION}.tar.gz"
SHA256="99ad89281a4fe85bc9fcf70b1d0842aa69d55361cf7c509e1acd3b0a0f8b5ba6"

# The triples build.zig looks for; keep in sync with README/AGENTS.md.
DEFAULT_TARGETS=(x86_64-linux-gnu aarch64-linux-gnu riscv64-linux-gnu)
targets=("$@")
[ ${#targets[@]} -eq 0 ] && targets=("${DEFAULT_TARGETS[@]}")

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for tool in cmake make curl tar zig; do
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

for target in "${targets[@]}"; do
    echo "Building librats $LIBRATS_VERSION for $target"
    build_dir="$tmp_dir/build-$target"

    # cmake wants a single compiler path, and the target has to ride along, so
    # each target gets a two-line wrapper.
    printf '#!/bin/sh\nexec zig cc -target %s "$@"\n' "$target" >"$tmp_dir/cc-$target"
    printf '#!/bin/sh\nexec zig c++ -target %s "$@"\n' "$target" >"$tmp_dir/cxx-$target"
    chmod +x "$tmp_dir/cc-$target" "$tmp_dir/cxx-$target"

    # Tests, the reference client and the examples are not part of the vendored
    # library. Static only: the binary must not need librats.so at runtime.
    cmake -S "$src_dir" -B "$build_dir" \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR="${target%%-*}" \
        -DCMAKE_C_COMPILER="$tmp_dir/cc-$target" \
        -DCMAKE_CXX_COMPILER="$tmp_dir/cxx-$target" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-g0" \
        -DCMAKE_CXX_FLAGS="-g0" \
        -DRATS_VERSION_OVERRIDE="$LIBRATS_VERSION" \
        -DRATS_BUILD_TESTS=OFF \
        -DRATS_BUILD_CLIENT=OFF \
        -DRATS_BUILD_EXAMPLES=OFF \
        -DRATS_STATIC_LIBRARY=ON \
        -DRATS_SHARED_LIBRARY=OFF >/dev/null

    cmake --build "$build_dir" -j"$(nproc)" >/dev/null

    # `cmake --install` is what puts the generated librats/util/version.h (and
    # features.h) beside the public headers; the release archive ships neither.
    cmake --install "$build_dir" --prefix "$tmp_dir/prefix-$target" >/dev/null

    # Replace any earlier unpack rather than merging into it, so a version bump
    # cannot leave stale headers behind.
    vendor_dir="$repo_root/vendor/librats/$target"
    rm -rf "$vendor_dir"
    mkdir -p "$vendor_dir"
    cp -r "$tmp_dir/prefix-$target/include" "$vendor_dir/include"
    cp "$tmp_dir/prefix-$target/lib/librats.a" "$vendor_dir/librats.a"
    echo "  vendor/librats/$target ($(du -h "$vendor_dir/librats.a" | cut -f1))"
done

echo "Vendored librats $LIBRATS_VERSION for: ${targets[*]}"
