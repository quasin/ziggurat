# ziggurat

A Zig 0.17.0 executable. The scaffold is a working CLI: it parses its own
arguments, reports its version from `build.zig.zon`, and exits — replace the
`run` branch in `src/main.zig` with the real work.

## Build and run

    zig build                       # -> zig-out/bin/ziggurat
    zig build run -- --version      # pass arguments after `--`
    zig build test                  # unit tests

Requires Zig 0.17.0 (`build.zig.zon` `.minimum_zig_version`); no dependencies.

## License

MIT — see [LICENSE](LICENSE).
