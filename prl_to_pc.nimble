# Package
version       = "0.3.0"
author        = "AlexJb"
description   = "Convert Qt .prl files to pkg-config .pc files"
license       = "MIT"
# SOURCE-ONLY manifest, full-tree store copies — both load-bearing for
# consumers that pin this repo as a nimble dependency (status-desktop):
#  - no `bin`: nimble 0.22.x builds dependency binaries UNCONDITIONALLY
#    during every consumer's `nimble setup` (there is no skip mechanism).
#    The tools are built on demand by qt_pkgconfig.nims / qt-pkgconfig.mk.
#  - no `srcDir`: nimble hoists a srcDir package's store copy (srcDir
#    contents moved to the entry root, EVERYTHING else dropped) — which
#    would strip qt_pkgconfig.nims, qt-pkgconfig.mk and the committed Qt .pc
#    trees, the whole point of consuming this package. Without srcDir the
#    full repo tree is materialized (sources stay importable under src/;
#    nothing imports them as modules anyway).
#
# 0.3.0 adds the nimscript consumer interface, qt_pkgconfig.nims, EXECUTED as
# `nim e <package root>/qt_pkgconfig.nims <env|tools|generate>`. It publishes
# the same knowledge qt-pkgconfig.mk does — kit derivation, the
# System/Generated probe, tool building, .pc generation — to consumers that do
# not use make. qt-pkgconfig.mk is retained unchanged: this is an interface
# addition, and no make consumer has to migrate.

# Dependencies. The generator dep is pinned by revision: name-form requires
# in dependency manifests make consumer solves nondeterministic (candidate
# tables drift across machines/days), and unpinned ranges enumerate every
# candidate version. unicodedb (regex's own dep) is pinned too so its range
# never enumerates. Keep in sync with status-desktop's pins.
requires "nim >= 1.6.0"
requires "https://github.com/nitely/nim-regex.git#2c41f0b2fee9fe78cf22f029bc854a77ac2e9768"  # regex
requires "https://github.com/nitely/nim-unicodedb.git#8938e71cdb3332b8a16eb27a6984c8565ea4643e"  # unicodedb

# Build the unified pkg-config wrapper -> `pkg-config` (`pkg-config.exe` on
# Windows), so it can shadow the real tool on PATH. The wrapper is dependency-free
# (no `regex`), so this compiles cleanly with plain `nim c`. Invoked as
# `nimble build` (nimbus-build-system's nimble runs .nimble TASKS via nim).
task build, "Build the unified pkg-config wrapper (pkg-config[.exe])":
  exec "nim c -d:release --hints:off --skipParentCfg:on -o:pkg-config src/pkgconfig_wrapper.nim"

# Unit-tests the wrapper logic, both consumer interfaces against the same three
# fixture Kits (make and nimscript), plus a minimal-project compile check that
# the committed .pc resolve correct Qt include paths per platform
# (kits/compilers that are absent are skipped, so this is runnable on any one
# machine / CI leg).
task test, "Run prl-to-pc tests":
  exec "nim c -r --hints:off --skipParentCfg:on --path:src tests/test_pkgconfig_wrapper.nim"
  exec "nim c -r --hints:off --skipParentCfg:on --path:src tests/test_qt_pkgconfig_mk.nim"
  exec "nim c -r --hints:off --skipParentCfg:on --path:src tests/test_qt_pkgconfig_nims.nim"
  exec "nim c -r --hints:off --skipParentCfg:on --path:src tests/test_committed_pc_compile.nim"

# Tasks
task convert, "Convert .prl files to .pc files in a directory":
  echo "Converting .prl files to .pc files"
  for i in 1..paramCount():
    echo "Param " & $i & ": " & paramStr(i)
    if paramStr(i) == "convert":
      let inputDir = paramStr(i+1)
      let outputDir = paramStr(i+2)
      let prefix = paramStr(i+3)
      let hostBins = if i+4 <= paramCount(): paramStr(i+4) else: ""
      exec "nim c -r src/prl_to_pc.nim " & inputDir & " " & outputDir & " " & prefix & " " & hostBins
      break