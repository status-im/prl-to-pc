# prl-to-pc — relocatable pkg-config for Qt kits

Qt ships `.prl` (qmake link metadata) files instead of pkg-config `.pc`
files. This repo makes any Qt kit consumable through the standard
`pkg-config` interface, on every platform, without a per-machine setup step.

It is three layers plus **two consumer interfaces** that glue them together —
`qt_pkgconfig.nims` for nimscript/nimble consumers and `qt-pkgconfig.mk` for
GNU make. Both publish the same knowledge (kit derivation, the System/Generated
probe, tool building, `.pc` generation); pick whichever your build speaks.

1. **Committed, relocatable `.pc` trees** — one per Qt version/kit, mirroring
   Qt's own layout:

   ```
   <version>/<kit>/lib/pkgconfig/*.pc      # e.g. 6.11.0/macos/lib/pkgconfig
   ```

   Currently committed for Qt 6.11.0: `macos`, `ios`, `android_arm64_v8a`,
   `msvc2022_64`. Each `.pc` bakes the placeholder prefix `@@QT_PREFIX@@`
   instead of a real path — the tree is machine-independent and the real
   prefix is supplied at query time (layer 3).

2. **The generator** (`src/prl_to_pc.nim`) — converts a kit's `.prl` files
   (and iOS `.framework`s) into those `.pc` files. It reconstructs what
   `.prl` files don't carry: `Requires:` edges come from the .prl's
   CMake-libs line, or from Qt's `<Module>Dependencies.cmake` on platforms
   whose `.prl`s have no dependency info (Windows); static/framework/ABI
   variants get correct `Libs:`/`Cflags:`; everything is emitted
   `${prefix}`-relative so the tree stays relocatable.

3. **A unified `pkg-config` wrapper** (`src/pkgconfig_wrapper.nim`) — built
   as `pkg-config` (`.exe` on Windows) and placed first on `PATH`, shadowing
   the real tool. For package names matching `PKG_CONFIG_PREFIX_OVERRIDE` it
   prepends `--define-variable=prefix=<real prefix>` and delegates to the
   first real `pkgconf`/`pkg-config` found on `PATH` (recursion-guarded
   three ways). This is what resolves `@@QT_PREFIX@@` to the actual kit:

   ```
   PKG_CONFIG_PREFIX_OVERRIDE='Qt*=/Users/you/Qt/6.11.0/macos'   # pattern=prefix, comma-separated
   PKG_CONFIG_ARCH='arm64-v8a'   # android single-arch kits only: Qt6Core -> Qt6Core_arm64-v8a
   PKG_CONFIG_PATH=<this repo>/6.11.0/macos/lib/pkgconfig
   ```

   The wrapper also strips trailing whitespace from output (Nim's `gorge`
   keeps the LF of a CRLF, which breaks numeric parsing in consumers like
   seaqt). For non-matching packages it is a transparent pass-through.

4. **`qt_pkgconfig.nims`** (nimscript) and **`qt-pkgconfig.mk`** (GNU make) —
   two zero-config consumer interfaces that wire the above together.

A real `pkg-config` or `pkgconf` must exist somewhere on `PATH`; the wrapper
delegates to it and refuses to run if it can only find itself.

## Consuming from nimscript (`qt_pkgconfig.nims`)

**Execute it — never `include` or `import` it:**

```nim
exec "nim e --skipParentCfg:on " & quoteShell(packageRoot / "qt_pkgconfig.nims") &
  " env " & quoteShell(myBuildDir)
```

`include`/`import` resolve at *parse* time while the `--path` switches
`nimble.paths` supplies only take effect at script *runtime* — and a nimble
consumer reaches this package through a **dynamic store path**
(`<store>/pkgs2/prl_to_pc-<version>-<checksum>`). No consumer `config.nims` can
therefore name this file at parse time. Executing it is the only shape that
works.

The only inputs are `QMAKE` (defaults to `qmake` on `PATH`) and `QT_PC_NIM`
(defaults to `nim`) — the same two the mk takes. `--skipParentCfg:on` keeps the
consumer's own `config.nims` out of the evaluation.

| subcommand | purpose |
|---|---|
| `env [<buildDir>]` | print the kit's pkg-config environment as `KEY=VAL` lines on stdout; builds and writes nothing |
| `tools <buildDir> <consumerPaths>` | build the wrapper + generator into `<buildDir>` (no-op in System mode; re-runs are no-ops) |
| `generate [<buildDir> [<consumerPaths>]]` | (re)generate this kit's committed `.pc` tree; **refuses on a store copy** |

`env` prints `QT_PC_MODE` (`system`/`generated`), `QT_PC_REASON`,
`QT_PC_PREFIX` and `PKG_CONFIG_PATH` in both modes, plus — Generated mode only
— `PKG_CONFIG_PREFIX_OVERRIDE`, `PKG_CONFIG_ARCH` (android kits) and
`QT_PC_PATH_PREPEND` (the wrapper dir, to be prepended to `PATH`).
`PKG_CONFIG_PATH` and `QT_PC_PATH_PREPEND` are values to **prepend**; the rest
are set outright. In System mode no wrapper exists, so a consumer must not
assume one does. `PKG_CONFIG_PATH` is printed in System mode too: without it
`pkg-config` answers from its built-in search path (a brew/distro Qt), not the
kit `QMAKE` selects.

Because `env` costs two `qmake` subprocesses and a probe, consumers are
expected to run it **once per build** and cache the result, keyed on the qmake
path, this package's root and the kit. `<buildDir>` only names where the
wrapper lives (default `<root>/.pcwrap`); consumers of a read-only store copy
pass their own. `<consumerPaths>` is the consumer's `nimble.paths`, needed
because the generator imports `regex` (see below).

Reference consumer: status-desktop — `status.nims` runs `tools` then caches
`env`; `config.nims` replays the cache.

## Consuming from a Makefile (`qt-pkgconfig.mk`)

```make
include path/to/prl-to-pc/qt-pkgconfig.mk
```

The **only input is `QMAKE`** (defaults to `qmake` on `PATH`) — the kit,
version, platform and android ABI are all derived from
`qmake -query QT_INSTALL_PREFIX`.

The include picks one of two modes automatically at make parse time
(re-decided on every invocation, so switching kits needs no cleaning). The
probe: with the kit's own `pkgconfig` dir prepended to `PKG_CONFIG_PATH`,
`pkg-config --variable=libdir Qt6Core` must string-equal
`qmake -query QT_INSTALL_LIBS` exactly. A one-line `$(info …)` reports the
chosen mode and reason.

- **System mode** (probe passes): the kit already ships usable `.pc`
  metadata — its `pkgconfig` dir is prepended to `PKG_CONFIG_PATH` and the
  system `pkg-config` is used as-is. Nothing is built, `PATH` and the
  override env are untouched, and all three targets are no-ops.
- **Generated mode** (any probe failure — no pkg-config, no `Qt6Core.pc`,
  or a broken prefix whose libdir differs): the behavior described in the
  rest of this README — the wrapper (and, only when needed, the generator)
  is built into `QT_PC_BUILD_DIR`, this kit's committed `.pc` tree is
  selected (or generation scheduled when the kit has none), and the wrapper
  env is exported (`PKG_CONFIG_PATH`, `PKG_CONFIG_PREFIX_OVERRIDE`,
  `PKG_CONFIG_ARCH` on android, wrapper dir prepended to `PATH`) so recipes
  and Nim-compile-time `gorge("pkg-config …")` calls just work.

Targets (all no-ops in System mode):

| target | purpose |
|---|---|
| `qt-pkgconfig` | aggregate: wrapper built + this kit's `.pc` tree present. Add as an order-only prerequisite of your build. |
| `qt-pkgconfig-tools` | build wrapper + generator executables. |
| `qt-pkgconfig-generate` | (re)generate this kit's `.pc` tree from the `QMAKE` kit — run on a Qt version bump and **commit the result**. |

Variables the includer may read: `QT_PCFILEDIR` (the active kit's `.pc` dir
— the kit's own in System mode, the committed tree in Generated mode),
`QT_PC_PKGCONFIG` (the pkg-config to invoke — system tool vs built wrapper),
`QT_PC_GENERATOR` (Generated mode only), `QT_PC_PREFIX` (real kit prefix).

Consumer-overridable knobs, Generated mode only (set **before** the
`include`):

- `QT_PC_BUILD_DIR` (default `<this repo>/.pcwrap`) — where the wrapper and
  generator binaries are built. **Must be overridden to a consumer-local dir
  when this repo is consumed as a read-only copy** (e.g. a nimble store
  entry); nothing may write into such a copy.
- `QT_PC_CONSUMER_PATHS` (default `<this repo>/../../nimble.paths`) — a
  nimble `nimble.paths` file used to resolve the generator's `regex`/
  `unicodedb` dependencies when the sibling-checkout layout (below) is
  absent.
- `QT_PC_NIM` (default `nim`) — the Nim compiler used to build the tools.

### How the generator's own deps resolve

The wrapper is dependency-free; only the generator imports `regex`. Its
build resolves paths in this order:

1. sibling checkouts `../nim-regex/src` + `../nim-unicodedb/src` (the
   vendored-submodule layout — offline);
2. explicit `--path` flags parsed from `QT_PC_CONSUMER_PATHS`;
3. nothing — a standalone clone falls back to Nim's default nimblepath
   (`nimble install regex`). Caveat: Nim **disables** its default
   `~/.nimble/pkgs2` search when the compile's working directory contains a
   `nimble.lock`, so consumers with a lock file must provide 1 or 2.

## Consuming as a nimble dependency

```nim
requires "https://github.com/status-im/prl-to-pc.git#v0.3.0"
```

The package is consumed as **package-root files** (the two consumer interfaces
and the `.pc` trees), not as Nim modules. Its manifest deliberately declares
**neither `bin` nor `srcDir`** — both are load-bearing for store copies on
nimble 0.22.x:

- a dependency with `bin` is **built unconditionally during every consumer's
  `nimble setup`** (there is no skip mechanism); the tools are built on
  demand by `qt_pkgconfig.nims` / `qt-pkgconfig.mk` instead;
- a dependency with `srcDir` gets its store copy **hoisted and stripped to
  the srcDir contents** — the interfaces and the `.pc` trees would simply
  not exist in the store. Without it, the full repo tree is materialized.

`regex`/`unicodedb` are pinned by revision (name-form requires in dependency
manifests make consumer solves nondeterministic).

The consumer resolves the package root from its generated `nimble.paths`
(the `pkgs2/prl_to_pc-…` entry), then either executes
`<root>/qt_pkgconfig.nims` or includes `<root>/qt-pkgconfig.mk`, pointing the
tool build at a consumer-local directory. Store copies are read-only pinned
content: `generate` detects them (`nimblemeta.json` at the package root) and
**refuses to write** — new kits are generated from a real checkout and
committed upstream. Reference consumer: status-desktop (`status.nims` +
`config.nims` + the `nim develop status.nims prl-to-pc` flow; its Makefile
still includes the mk for legs that have not migrated).

## Adding a kit / bumping Qt

From a real checkout (not a store copy), with the target kit's qmake:

```bash
QMAKE=~/Qt/6.12.0/macos/bin/qmake nim e --skipParentCfg:on qt_pkgconfig.nims generate
# or, for make consumers:
QMAKE=~/Qt/6.12.0/macos/bin/qmake make -f qt-pkgconfig.mk qt-pkgconfig-generate
git add 6.12.0/macos/lib/pkgconfig && git commit
```

(In status-desktop: `nim develop status.nims prl-to-pc`, then
`nim qtPkgconfigGenerate status.nims`.) Generation is idempotent — the kit's
output dir is wiped and rewritten. A kit the probe puts in System mode needs no
tree, and `generate` says so instead of writing one.

## Command-line usage

```bash
# Relocatable committed-tree mode (what qt-pkgconfig-generate runs):
# derives <version>/<kit> from the path, writes
# <out_root>/<version>/<kit>/lib/pkgconfig with the @@QT_PREFIX@@ placeholder.
prl_to_pc generate <qt_lib_dir> [out_root]

# Raw conversion with a literal prefix (host_bins defaults to ${prefix}/bin):
prl_to_pc [convert] <input_dir> <output_dir> <prefix> [host_bins]
```

Build the tools with `make -f qt-pkgconfig.mk qt-pkgconfig-tools`, or
directly: `nim c -d:release src/prl_to_pc.nim` (needs `regex` resolvable —
see above; the wrapper `src/pkgconfig_wrapper.nim` is dependency-free).

## Library usage

```nim
import prl_to_pc  # compile with --path:<repo>/src

# One .prl file / one iOS framework:
let module = parsePrlFile("path/to/Qt6Core.prl")
let fw     = parseFramework("path/to/QtCore.framework")

# Whole kit, literal prefix:
convertPrlToPc("qt/lib", "out/pkgconfig", "/path/to/qt/kit", "")

# Whole kit, relocatable committed-tree layout:
generateBundled("~/Qt/6.11.0/macos/lib", "out/root")
```

## Tests

```bash
nimble test
```

Runs the wrapper's unit tests (glob/override/arch-suffix logic), a hermetic
fixture-kit harness for **each** consumer interface — `qt-pkgconfig.mk` and
`qt_pkgconfig.nims` — over the same three fixture kits (System/Generated mode
selection, probe reasons, the store-copy generation refusal), and a
minimal-project compile check that each committed `.pc` tree resolves
correct include paths: it queries cflags through the wrapper and compiles a
tiny Qt translation unit per kit. Kits whose real Qt install or platform
compiler is absent are **skipped**, so the suite runs on any one machine
(real kits are looked up under `$QT_KITS_DIR/<kit>`, default
`$HOME/Qt/<version>/<kit>`).

## License

MIT — see [LICENSE](LICENSE).
