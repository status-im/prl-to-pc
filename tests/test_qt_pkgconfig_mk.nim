## tests/test_qt_pkgconfig_mk.nim
##
## Hermetic fixture-Kit harness for qt-pkgconfig.mk.
##
## Pins the public contract of qt-pkgconfig.mk across BOTH modes selected by the
## Probe (the parse-time libdir string-equality test between the Kit's own
## Qt6Core.pc and qmake's QT_INSTALL_LIBS).
##
## Three fixture Kit variants are exercised:
##
##   correct       Kit ships a Committed-tree-style pkgconfig/ dir whose
##                 Qt6Core.pc libdir matches qmake's QT_INSTALL_LIBS answer.
##                 The Probe passes → System mode.
##
##   broken-prefix Kit ships a pkgconfig/ dir whose Qt6Core.pc libdir points at
##                 a build-farm path (Broken prefix, e.g. /Users/qt/work/install).
##                 The Probe sees a libdir mismatch → Generated mode.
##
##   no-pc         Kit ships no pkgconfig/ dir at all (mobile-Kit shape).
##                 The Probe finds no usable Qt6Core.pc → Generated mode.
##
## In System mode the module builds nothing, leaves PATH untouched, exports no
## prefix-override/arch, uses the system pkg-config, and points QT_PCFILEDIR at
## the Kit's own pkgconfig dir. In Generated mode it behaves exactly as before:
## the Wrapper is built, PATH is shadowed, and the prefix-override env is wired.
##
## Requirements: make, nim on PATH, plus a real system pkg-config (the prl-to-pc
## repo's dev baseline) — the correct/System fixture needs pkg-config to answer
## the Probe.  No real Qt install required.  Each test run creates a fresh temp
## sandbox.

import std/[unittest, os, osproc, strutils]

const
  FakeVersion = "6.9.0"
  FakeKit     = "macos"

let here = currentSourcePath().parentDir()
let repo = here.parentDir()   # prl-to-pc root

# ─── sandbox helpers ─────────────────────────────────────────────────────────

proc freshSandbox(variant: string): string =
  ## Create (or recreate) a per-run temp sandbox; return its path.
  ## Using a deterministic name makes repeated runs idempotent.
  let d = getTempDir() / "prl_to_pc_mk_" & variant
  removeDir(d)
  createDir(d)
  d

proc stageModule(sandboxDir: string): string =
  ## Stage qt-pkgconfig.mk + src/ into <sandbox>/module/ so make runs inside
  ## the sandbox, not against the live checkout.  Returns the staged module dir.
  let modDir = sandboxDir / "module"
  createDir(modDir)
  copyFile(repo / "qt-pkgconfig.mk", modDir / "qt-pkgconfig.mk")
  let srcDst = modDir / "src"
  createDir(srcDst)
  for kind, path in walkDir(repo / "src"):
    if kind == pcFile:
      copyFile(path, srcDst / path.extractFilename)
  modDir

proc seedCommittedTree(modDir: string) =
  ## Pre-seed a minimal Qt6Core.pc in the Committed tree location so
  ## QT_PC_HAVE_PC is non-empty at make-parse time.  This prevents make from
  ## invoking the generator, which avoids the nim-regex dependency and keeps
  ## the sandbox fully self-contained (wrapper only — no prl_to_pc build).
  let pcDir = modDir / FakeVersion / FakeKit / "lib" / "pkgconfig"
  createDir(pcDir)
  writeFile(pcDir / "Qt6Core.pc",
    "prefix=@@QT_PREFIX@@\n" &
    "libdir=${prefix}/lib\n" &
    "Name: Qt6Core\nDescription: Qt6Core\nVersion: " & FakeVersion & "\n")

proc createFakeQmake(sandboxDir, kitPrefix, kitLibs: string): string =
  ## Write a fake qmake shell script that answers -query QT_INSTALL_PREFIX and
  ## -query QT_INSTALL_LIBS.  Returns the script path.
  let binDir = sandboxDir / "bin"
  createDir(binDir)
  let qmakePath = binDir / "qmake"
  writeFile(qmakePath,
    "#!/bin/sh\n" &
    "case \"$2\" in\n" &
    "  QT_INSTALL_PREFIX) echo " & quoteShell(kitPrefix) & " ;;\n" &
    "  QT_INSTALL_LIBS)   echo " & quoteShell(kitLibs)   & " ;;\n" &
    "  *) exit 1 ;;\n" &
    "esac\n")
  setFilePermissions(qmakePath,
    {fpUserExec, fpUserRead, fpUserWrite,
     fpGroupRead, fpOthersRead})
  qmakePath

proc writeIncluderMk(sandboxDir, modDir: string): string =
  ## Write a minimal includer makefile that includes the staged module by
  ## absolute path and exposes print targets for each documented output variable
  ## and for the exported env as seen by a recipe (the surface seaqt uses).
  ## Returns the makefile path.
  let mk = sandboxDir / "includer.mk"
  writeFile(mk,
    "include " & modDir & "/qt-pkgconfig.mk\n" &
    "\n" &
    ".PHONY: print-vars\n" &
    "print-vars:\n" &
    "\t@echo QT_PCFILEDIR=$(QT_PCFILEDIR)\n" &
    "\t@echo QT_PC_PKGCONFIG=$(QT_PC_PKGCONFIG)\n" &
    "\t@echo QT_PC_PREFIX=$(QT_PC_PREFIX)\n" &
    "\t@echo PKG_CONFIG_PATH_ENV=$$PKG_CONFIG_PATH\n" &
    "\t@echo PKG_CONFIG_PREFIX_OVERRIDE_ENV=$$PKG_CONFIG_PREFIX_OVERRIDE\n" &
    "\t@echo PKG_CONFIG_ARCH_ENV=$$PKG_CONFIG_ARCH\n" &
    "\t@echo PATH_FIRST=$$(echo $$PATH | cut -d: -f1)\n")
  mk

proc runMake(includerMk, qmakePath, target: string): tuple[output: string, code: int] =
  let cmd = "make -f " & quoteShell(includerMk) &
    " QMAKE=" & quoteShell(qmakePath) &
    " " & target
  let (outp, code) = execCmdEx(cmd)
  (outp, code)

proc parseKV(output: string): seq[tuple[k, v: string]] =
  ## Parse "KEY=VALUE" lines from make output (ignoring blank lines).
  ## The Probe's $(info ...) report line carries no '=' and is skipped.
  for line in output.splitLines:
    let trimmed = line.strip()
    if trimmed.len == 0: continue
    let sep = trimmed.find('=')
    if sep < 0: continue
    result.add (trimmed[0 ..< sep], trimmed[sep + 1 .. ^1])

proc valueOf(pairs: seq[tuple[k, v: string]], key: string): string =
  for p in pairs:
    if p.k == key: return p.v
  ""

# ─── fixture Kit constructors ─────────────────────────────────────────────────

proc makeCorrectKit(sandboxDir, kitLibDir: string) =
  ## correct variant: kit ships lib/pkgconfig/Qt6Core.pc with libdir equal to
  ## QT_INSTALL_LIBS (what the Probe checks for System mode).  A Description
  ## field is required or pkg-config(pkgconf) rejects the file and falls through
  ## to some other Qt6Core on the ambient PKG_CONFIG_PATH.
  let pcDir = kitLibDir / "pkgconfig"
  createDir(pcDir)
  let kitRoot = sandboxDir / "fakekit" / FakeVersion / FakeKit
  writeFile(pcDir / "Qt6Core.pc",
    "prefix=" & kitRoot & "\n" &
    "libdir=" & kitLibDir & "\n" &
    "Name: Qt6Core\nDescription: Qt6Core\nVersion: " & FakeVersion & "\n")

proc makeBrokenPrefixKit(kitLibDir: string) =
  ## broken-prefix variant: kit ships lib/pkgconfig/Qt6Core.pc with a build-farm
  ## libdir that does NOT match QT_INSTALL_LIBS (Broken prefix).
  let pcDir = kitLibDir / "pkgconfig"
  createDir(pcDir)
  writeFile(pcDir / "Qt6Core.pc",
    "prefix=/Users/qt/work/install\n" &
    "libdir=/Users/qt/work/install/lib\n" &
    "Name: Qt6Core\nDescription: Qt6Core\nVersion: " & FakeVersion & "\n")

proc makeNoPcKit(kitLibDir: string) =
  ## no-pc variant: kit ships no pkgconfig/ dir (mobile-Kit shape).
  createDir(kitLibDir)  # lib/ dir present, but pkgconfig/ absent

# ─── contract verifiers ───────────────────────────────────────────────────────

proc checkGeneratedModeContract(sandboxDir, modDir, qmakePath: string,
                                specificReason: string = "") =
  ## Assert the full Generated mode contract for the current sandbox, including
  ## the Probe's mode report line.  When specificReason is non-empty it is also
  ## checked (in addition to the broad "generated mode" substring) so callers
  ## can pin the exact diagnostic message for no-pc vs broken-prefix kits.

  let includerMk = writeIncluderMk(sandboxDir, modDir)

  let wrapperPath  = modDir / ".pcwrap" / "pkg-config"
  let pcfiledir    = modDir / FakeVersion / FakeKit / "lib" / "pkgconfig"
  let kitPrefix    = sandboxDir / "fakekit" / FakeVersion / FakeKit

  # ── 1. Variable contract (parse-time exports) ────────────────────────────
  let (varsOut, varsCode) = runMake(includerMk, qmakePath, "print-vars")
  doAssert varsCode == 0, "make print-vars failed:\n" & varsOut

  # The Probe reports Generated mode.
  check varsOut.contains("generated mode")
  if specificReason.len > 0:
    check varsOut.contains(specificReason)

  let kv = parseKV(varsOut)

  # QT_PCFILEDIR points at the Committed tree location inside the staged module.
  check valueOf(kv, "QT_PCFILEDIR") == pcfiledir

  # QT_PC_PKGCONFIG is the Wrapper path (Generated mode).
  check valueOf(kv, "QT_PC_PKGCONFIG") == wrapperPath

  # QT_PC_PREFIX is the Kit prefix returned by fake qmake.
  check valueOf(kv, "QT_PC_PREFIX") == kitPrefix

  # PKG_CONFIG_PATH has the Committed tree dir prepended.
  let pkgCfgPath = valueOf(kv, "PKG_CONFIG_PATH_ENV")
  check pkgCfgPath.startsWith(pcfiledir)

  # The INTERNAL prefix override is exported (Generated mode only).
  check valueOf(kv, "PKG_CONFIG_PREFIX_OVERRIDE_ENV") == "Qt*=" & kitPrefix

  # PATH has the .pcwrap dir prepended (Wrapper is first on PATH).
  check valueOf(kv, "PATH_FIRST") == modDir / ".pcwrap"

  # ── 2. qt-pkgconfig target: Wrapper binary must be produced ──────────────
  let (buildOut, buildCode) = runMake(includerMk, qmakePath, "qt-pkgconfig")
  doAssert buildCode == 0, "make qt-pkgconfig failed:\n" & buildOut

  check fileExists(wrapperPath)

proc checkSystemModeContract(sandboxDir, modDir, qmakePath: string) =
  ## Assert the full System mode contract for the current sandbox: system
  ## pkg-config, Kit's own pkgconfig dir, PATH untouched, no prefix-override/arch
  ## export, and the qt-pkgconfig target a no-op that builds nothing.

  let includerMk = writeIncluderMk(sandboxDir, modDir)

  let wrapperPath  = modDir / ".pcwrap" / "pkg-config"
  let kitPrefix    = sandboxDir / "fakekit" / FakeVersion / FakeKit
  let kitPcDir     = kitPrefix / "lib" / "pkgconfig"
  let wrapDir      = modDir / ".pcwrap"

  # ── 1. Variable contract (parse-time exports) ────────────────────────────
  let (varsOut, varsCode) = runMake(includerMk, qmakePath, "print-vars")
  doAssert varsCode == 0, "make print-vars failed:\n" & varsOut

  # The Probe reports System mode.
  check varsOut.contains("system mode")

  let kv = parseKV(varsOut)

  # QT_PCFILEDIR points at the Kit's OWN pkgconfig dir.
  check valueOf(kv, "QT_PCFILEDIR") == kitPcDir

  # QT_PC_PKGCONFIG is the system pkg-config (by command name).
  check valueOf(kv, "QT_PC_PKGCONFIG") == "pkg-config"

  # QT_PC_PREFIX is the Kit prefix returned by fake qmake.
  check valueOf(kv, "QT_PC_PREFIX") == kitPrefix

  # PKG_CONFIG_PATH has the Kit's own pkgconfig dir prepended.
  let pkgCfgPath = valueOf(kv, "PKG_CONFIG_PATH_ENV")
  check pkgCfgPath.startsWith(kitPcDir)

  # No prefix-override / arch is exported in System mode.
  check valueOf(kv, "PKG_CONFIG_PREFIX_OVERRIDE_ENV") == ""
  check valueOf(kv, "PKG_CONFIG_ARCH_ENV") == ""

  # PATH is untouched by the module — the Wrapper dir is NOT prepended.
  check valueOf(kv, "PATH_FIRST") != wrapDir

  # ── 2. qt-pkgconfig target: a no-op that builds nothing ──────────────────
  let (buildOut, buildCode) = runMake(includerMk, qmakePath, "qt-pkgconfig")
  doAssert buildCode == 0, "make qt-pkgconfig failed:\n" & buildOut

  # Nothing compiled: the Wrapper must NOT exist.
  check not fileExists(wrapperPath)

# ─── test cases ──────────────────────────────────────────────────────────────

suite "qt-pkgconfig.mk: Probe-selected mode contract":

  test "correct Kit — Probe selects System mode":
    ## correct Kit ships a pkgconfig/ dir whose Qt6Core.pc libdir matches
    ## QT_INSTALL_LIBS, so the Probe selects System mode: system pkg-config,
    ## Kit's own pkgconfig dir, nothing built, PATH untouched.
    let sb = freshSandbox("correct")
    let modDir = stageModule(sb)
    seedCommittedTree(modDir)
    let kitPrefix = sb / "fakekit" / FakeVersion / FakeKit
    let kitLibs   = kitPrefix / "lib"
    let qmake = createFakeQmake(sb, kitPrefix, kitLibs)
    makeCorrectKit(sb, kitLibs)
    checkSystemModeContract(sb, modDir, qmake)

  test "broken-prefix Kit — Probe falls back to Generated mode":
    ## broken-prefix Kit ships a pkgconfig/ dir with Broken prefix paths, so the
    ## Probe sees a libdir mismatch and falls back to Generated mode.  The reason
    ## must say "libdir mismatch (broken prefix)", not "ships no Qt6Core.pc".
    let sb = freshSandbox("broken")
    let modDir = stageModule(sb)
    seedCommittedTree(modDir)
    let kitPrefix = sb / "fakekit" / FakeVersion / FakeKit
    let kitLibs   = kitPrefix / "lib"
    let qmake = createFakeQmake(sb, kitPrefix, kitLibs)
    makeBrokenPrefixKit(kitLibs)
    checkGeneratedModeContract(sb, modDir, qmake, "libdir mismatch (broken prefix)")

  test "no-pc Kit — Probe falls back to Generated mode":
    ## no-pc Kit ships no pkgconfig/ dir at all (mobile-Kit shape), so the Probe
    ## finds no usable Qt6Core.pc and falls back to Generated mode.  The reason
    ## must say "kit ships no Qt6Core.pc in <kitpcdir>" (deterministic wildcard
    ## check), not "libdir mismatch" — even on machines where brew pkg-config
    ## would otherwise resolve an ambient Qt6Core.pc and make the probe non-empty.
    let sb = freshSandbox("nopc")
    let modDir = stageModule(sb)
    seedCommittedTree(modDir)
    let kitPrefix = sb / "fakekit" / FakeVersion / FakeKit
    let kitLibs   = kitPrefix / "lib"
    let qmake = createFakeQmake(sb, kitPrefix, kitLibs)
    makeNoPcKit(kitLibs)
    checkGeneratedModeContract(sb, modDir, qmake, "kit ships no Qt6Core.pc")
