# Ziggurat

Ziggurat - simple pet project.

Linked against [librats](https://github.com/librats/librats) 3.0.3, built from
source as a static archive; `--help` prints the version the library reports.

## Build and run

    bash scripts/fetch-librats.sh   # once: vendors librats into vendor/librats/
    zig build                       # -> zig-out/bin/ziggurat
    zig build run -- --version      # pass arguments after `--`
    zig build test                  # unit tests

Requires Zig 0.17.0 (`build.zig.zon` `.minimum_zig_version`), and `cmake`,
`g++`, `make`, `curl`, `tar` for the librats build.

## License

MIT — see [LICENSE](LICENSE).
