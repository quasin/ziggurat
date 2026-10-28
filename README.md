# Ziggurat

Ziggurat - simple pet project.

Linked against [librats](https://github.com/librats/librats) 3.0.3, built from
source as a static archive per target; `--help` prints the version the library
reports.

## Build and run

    bash scripts/fetch-librats.sh   # once: vendors librats for three targets
    zig build                       # -> zig-out/bin/ziggurat (host)
    zig build dist                  # -> zig-out/<triple>/ziggurat (ReleaseSafe, stripped)
    zig build run -- --version      # pass arguments after `--`
    zig build test                  # unit tests

`zig build dist` produces:

    x86_64-linux-gnu/ziggurat
    aarch64-linux-gnu/ziggurat
    riscv64-linux-gnu/ziggurat

A single target can be built directly:

    zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe

Requires Zig 0.17.0 (`build.zig.zon` `.minimum_zig_version`), and `cmake`,
`make`, `curl`, `tar` for the librats build. No cross toolchain is needed:
librats is compiled by `zig c++ -target <triple>`.

## License

MIT — see [LICENSE](LICENSE).
