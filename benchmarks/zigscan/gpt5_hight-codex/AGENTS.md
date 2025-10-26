# Repository Guidelines

## Project Structure & Module Organization
- Use Zig 0.15.1 (see `zig-0.15.1` and `zig-Language-Reference-0.15.1.txt`).
- Expected layout:
  - `build.zig` (project build script)
  - `src/` → `main.zig`, `cli.zig`, `scanner.zig`, `format.zig`
  - `test/` → focused unit tests (optional integration)
  - `.zig-cache/` → build cache (do not commit)

## Build, Test, and Development Commands
- Format: `zig fmt .`
- Build (with build.zig): `zig build`  • Run: `zig build run -- --help`
- Direct compile (no build.zig yet): `zig build-exe src/main.zig -O ReleaseFast -fstrip`
- Tests (build.zig): `zig build test`  • Ad hoc: `zig test src/cli.zig`
- Example run: `zig build run -- --ports 80,443 --range 1-1024 --concurrency 500 192.168.1.1`

## Coding Style & Naming Conventions
- Indentation: 4 spaces. Keep lines ≤ 100 chars.
- Zig style: types `UpperCamelCase`; functions/vars/constants `lowerCamelCase`.
- Filenames: `snake_case.zig` (e.g., `port_parser.zig`).
- Prefer small modules; import with `const std = @import("std");` and `@import("scanner.zig");`.
- Run `zig fmt .` before pushing.

## Testing Guidelines
- Use Zig built-in tests via `test { }` blocks.
- Unit tests for argument parsing, port list/range parsing, concurrency limits, and output formatting.
- Keep tests deterministic; avoid real network scanning. If adding integration tests, gate via a build option (e.g., `-Denable_integration=true`).

## Commit & Pull Request Guidelines
- Use Conventional Commits (e.g., `feat: add CIDR parsing`, `fix: timeout handling`).
- PRs must include: purpose, key changes, how to run, and sample output. Add benchmarks if performance-relevant.
- Keep patches focused and minimal; update README when flags/usage change.

## Security & Configuration Tips
- Only scan targets you are authorized to test.
- Set reasonable defaults: conservative timeouts, bounded concurrency.
- No elevated privileges assumed; avoid platform-specific syscalls unless guarded.

## Agent-Specific Instructions
- 开发铁律: 使用系统安装的 `zig` 作为编译器；`./zig-0.15.1` 目录仅作为Zig 0.15.1源码参考，用于语法/兼容性查询，不用于编译（只读）。
- Follow Zig 0.15.1 syntax; consult `zig-Language-Reference-0.15.1.txt` and `./zig-0.15.1` as references.
- Prefer `zig build` scaffolding; do not modify `zig-0.15.1` symlink.
- Make targeted changes, respect this file’s conventions, and keep outputs reproducible.
