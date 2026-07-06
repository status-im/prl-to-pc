## tests/test_qt_pkgconfig_mk.nim
##
## Hermetic fixture-Kit harness for qt-pkgconfig.mk.
##
## Pins the public contract of qt-pkgconfig.mk in Generated mode — the only
## mode the module supports today, before the Probe is added in a later slice.
##
## Three fixture Kit variants are exercised:
##
##   correct       Kit ships a Committed tree style pkgconfig/ dir whose
##                 Qt6Core.pc libdir matches qmake's QT_INSTALL_LIBS answer.
##                 When the Probe arrives, this Kit selects System mode.
##
##   broken-prefix Kit ships a pkgconfig/ dir whose Qt6Core.pc libdir points at
##                 a build-farm path (Broken prefix, e.g. /Users/qt/work/install).
##                 The Probe will fall back to Generated mode for this variant.
##
##   no-pc         Kit ships no pkgconfig/ dir at all (mobile-Kit shape).
##                 The Probe will fall back to Generated mode.
##
## Under today's module (no Probe) all three variants produce identical
## observable behaviour: the Wrapper is built and the environment is wired for
## Generated mode.  The assertions encode that identity so the next slice's
## Probe introduction is observable as a deliberate assertion update.
##
## Requirements: make, nim on PATH (the prl-to-pc repo's dev baseline).
## No real Qt install required.  Each test run creates a fresh temp sandbox.

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
    "Name: Qt6Core\nVersion: " & FakeVersion & "\n")

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
  ## QT_INSTALL_LIBS (what the Probe checks for System mode).
  let pcDir = kitLibDir / "pkgconfig"
  createDir(pcDir)
  let kitRoot = sandboxDir / "fakekit" / FakeVersion / FakeKit
  writeFile(pcDir / "Qt6Core.pc",
    "prefix=" & kitRoot & "\n" &
    "libdir=" & kitLibDir & "\n" &
    "Name: Qt6Core\nVersion: " & FakeVersion & "\n")

proc makeBrokenPrefixKit(kitLibDir: string) =
  ## broken-prefix variant: kit ships lib/pkgconfig/Qt6Core.pc with a build-farm
  ## libdir that does NOT match QT_INSTALL_LIBS (Broken prefix).
  let pcDir = kitLibDir / "pkgconfig"
  createDir(pcDir)
  writeFile(pcDir / "Qt6Core.pc",
    "prefix=/Users/qt/work/install\n" &
    "libdir=/Users/qt/work/install/lib\n" &
    "Name: Qt6Core\nVersion: " & FakeVersion & "\n")

proc makeNoPcKit(kitLibDir: string) =
  ## no-pc variant: kit ships no pkgconfig/ dir (mobile-Kit shape).
  createDir(kitLibDir)  # lib/ dir present, but pkgconfig/ absent

# ─── contract verifier ───────────────────────────────────────────────────────

proc checkGeneratedModeContract(sandboxDir, modDir, qmakePath: string) =
  ## Assert the full Generated mode contract for the current sandbox.
  ## Called once per fixture variant; all three must satisfy the same contract
  ## while the module has no Probe.

  let includerMk = writeIncluderMk(sandboxDir, modDir)

  let wrapperPath  = modDir / ".pcwrap" / "pkg-config"
  let pcfiledir    = modDir / FakeVersion / FakeKit / "lib" / "pkgconfig"
  let kitPrefix    = sandboxDir / "fakekit" / FakeVersion / FakeKit

  # ── 1. Variable contract (parse-time exports) ────────────────────────────
  let (varsOut, varsCode) = runMake(includerMk, qmakePath, "print-vars")
  doAssert varsCode == 0, "make print-vars failed:\n" & varsOut

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

  # PATH has the .pcwrap dir prepended (Wrapper is first on PATH).
  check valueOf(kv, "PATH_FIRST") == modDir / ".pcwrap"

  # ── 2. qt-pkgconfig target: Wrapper binary must be produced ──────────────
  let (buildOut, buildCode) = runMake(includerMk, qmakePath, "qt-pkgconfig")
  doAssert buildCode == 0, "make qt-pkgconfig failed:\n" & buildOut

  check fileExists(wrapperPath)

# ─── test cases ──────────────────────────────────────────────────────────────

suite "qt-pkgconfig.mk: generated-mode contract (no Probe)":

  test "correct Kit — Generated mode (today identical to broken-prefix and no-pc)":
    ## correct Kit ships a pkgconfig/ dir whose Qt6Core.pc libdir matches
    ## QT_INSTALL_LIBS.  The upcoming Probe will select System mode for this Kit;
    ## today (no Probe) it still uses Generated mode, same as the others.
    let sb = freshSandbox("correct")
    let modDir = stageModule(sb)
    seedCommittedTree(modDir)
    let kitPrefix = sb / "fakekit" / FakeVersion / FakeKit
    let kitLibs   = kitPrefix / "lib"
    let qmake = createFakeQmake(sb, kitPrefix, kitLibs)
    makeCorrectKit(sb, kitLibs)
    checkGeneratedModeContract(sb, modDir, qmake)

  test "broken-prefix Kit — Generated mode":
    ## broken-prefix Kit ships a pkgconfig/ dir with Broken prefix paths.
    ## The Probe (next slice) will detect the mismatch and fall back to
    ## Generated mode; today (no Probe) the module always uses Generated mode.
    let sb = freshSandbox("broken")
    let modDir = stageModule(sb)
    seedCommittedTree(modDir)
    let kitPrefix = sb / "fakekit" / FakeVersion / FakeKit
    let kitLibs   = kitPrefix / "lib"
    let qmake = createFakeQmake(sb, kitPrefix, kitLibs)
    makeBrokenPrefixKit(kitLibs)
    checkGeneratedModeContract(sb, modDir, qmake)

  test "no-pc Kit — Generated mode":
    ## no-pc Kit ships no pkgconfig/ dir at all (mobile-Kit shape).
    ## The Probe (next slice) will not find Qt6Core.pc and will use Generated
    ## mode; today (no Probe) the module always uses Generated mode.
    let sb = freshSandbox("nopc")
    let modDir = stageModule(sb)
    seedCommittedTree(modDir)
    let kitPrefix = sb / "fakekit" / FakeVersion / FakeKit
    let kitLibs   = kitPrefix / "lib"
    let qmake = createFakeQmake(sb, kitPrefix, kitLibs)
    makeNoPcKit(kitLibs)
    checkGeneratedModeContract(sb, modDir, qmake)
