# qt-pkgconfig.mk — zero-config drop-in for consuming Qt via pkg-config in a seaqt
# build. Just `include` it; there is nothing to configure. The only requirements
# are `qmake` and `nim` (or `nimble`) on PATH.
#
# It derives everything from qmake and:
#   1. builds the pkg-config wrapper + the prl_to_pc generator into QT_PC_BUILD_DIR
#      (default <this-dir>/.pcwrap/; consumers of a read-only store copy override it);
#   2. ships, and auto-generates when missing, the committed relocatable Qt .pc tree
#      for the active kit under <this-dir>/<version>/<kit>/lib/pkgconfig;
#   3. exports the env seaqt's gorge("pkg-config ...") needs at nim-compile time
#      (PKG_CONFIG_PATH + the wrapper on PATH, plus an INTERNAL prefix override so the
#      relocatable @@QT_PREFIX@@ placeholder resolves to the real kit).
#
# To target a specific kit, set the standard QMAKE variable (defaults to `qmake` on
# PATH) — that is the ONLY input, and the desktop/mobile Makefiles already set it.
#
# Outputs the includer may use:
#   QT_PCFILEDIR     committed .pc dir for the active kit
#   QT_PC_PKGCONFIG  path to the built pkg-config wrapper (= QT_PC_WRAPPER)
#   QT_PC_GENERATOR  path to the built prl_to_pc generator
#   QT_PC_PREFIX     the real Qt install prefix (from qmake)
# Targets:
#   qt-pkgconfig           (aggregate) wrapper built + this kit's .pc present —
#                          add as an order-only prerequisite of your nim build.
#   qt-pkgconfig-tools     build both executables.
#   qt-pkgconfig-generate  force (re)generate this kit's .pc tree (Qt bump); commit it.

ifndef QT_PKGCONFIG_MK_INCLUDED
QT_PKGCONFIG_MK_INCLUDED := 1

# This file's own directory = the prl-to-pc root (committed .pc trees + src/).
QT_PC_SELF_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# Only external requirements: qmake + nim/nimble on PATH.
QMAKE ?= qmake
QT_PC_NIM ?= nim

# Derive the kit from qmake — no caller configuration.
QT_PC_PREFIX := $(shell $(QMAKE) -query QT_INSTALL_PREFIX)
ifeq ($(strip $(QT_PC_PREFIX)),)
 $(error qt-pkgconfig.mk: '$(QMAKE) -query QT_INSTALL_PREFIX' produced nothing — is qmake on PATH?)
endif
QT_PC_KIT := $(notdir $(QT_PC_PREFIX))
QT_PC_VER := $(notdir $(patsubst %/,%,$(dir $(QT_PC_PREFIX))))

# Windows toolchains: PKG_CONFIG_PATH uses ';' and the built tools take '.exe'.
ifeq ($(OS),Windows_NT)
 QT_PC_EXE := .exe
 QT_PC_PATHSEP := ;
else
 QT_PC_EXE :=
 QT_PC_PATHSEP := :
endif

# Android single-arch kits suffix their libs/.pc (libQt6Core_arm64-v8a.so ->
# Qt6Core_arm64-v8a.pc); the wrapper appends this ABI to bare module names so
# seaqt's `pkg-config Qt6Core` resolves. Derived from the kit name, never configured.
ifeq ($(QT_PC_KIT),android_arm64_v8a)
 QT_PC_ARCH := arm64-v8a
else ifeq ($(QT_PC_KIT),android_armv7)
 QT_PC_ARCH := armeabi-v7a
else ifeq ($(QT_PC_KIT),android_x86_64)
 QT_PC_ARCH := x86_64
else ifeq ($(QT_PC_KIT),android_x86)
 QT_PC_ARCH := x86
else
 QT_PC_ARCH :=
endif

QT_PCFILEDIR := $(QT_PC_SELF_DIR)/$(QT_PC_VER)/$(QT_PC_KIT)/lib/pkgconfig
# Is this kit's committed .pc tree already present? Decided at PARSE time (matches both
# bare Qt6Core.pc and the android arch-suffixed Qt6Core_<abi>.pc) so the generator is
# only pulled in when generation is actually needed — never on a normal build.
QT_PC_HAVE_PC := $(wildcard $(QT_PCFILEDIR)/Qt6Core.pc $(QT_PCFILEDIR)/Qt6Core_*.pc)

# Where the wrapper + generator executables are built. Consumer-overridable
# (set QT_PC_BUILD_DIR before including this file): when this repo is consumed
# as a READ-ONLY nimble store copy, in-package writes are forbidden — the
# consumer points the build at its own scratch dir instead. A plain checkout
# keeps the historical in-repo default.
QT_PC_BUILD_DIR ?= $(QT_PC_SELF_DIR)/.pcwrap
QT_PC_WRAPPER   := $(QT_PC_BUILD_DIR)/pkg-config$(QT_PC_EXE)
QT_PC_GENERATOR := $(QT_PC_BUILD_DIR)/prl_to_pc$(QT_PC_EXE)
QT_PC_PKGCONFIG := $(QT_PC_WRAPPER)

# A nimble store copy carries nimblemeta.json at the package root (a git
# checkout never does). Store copies are read-only pinned content: the
# generate path below must never write .pc trees into them.
QT_PC_STORE_COPY := $(wildcard $(QT_PC_SELF_DIR)/nimblemeta.json)

# The generator imports `regex`; auto-detect status-desktop's vendored copies
# (siblings of this submodule) so plain `nim c` builds it offline. When they are
# absent, fall back to the consumer repo's nimble-resolved store paths
# (QT_PC_CONSUMER_PATHS, consumer-overridable; defaults to a nimble.paths two
# levels up, i.e. next to a vendor/ that holds this repo — a store copy's
# consumer must set it to its own nimble.paths explicitly):
# nim DISABLES its default ~/.nimble/pkgs2 search when the compile's cwd
# contains a nimble.lock, so bare `import regex` resolution cannot be relied
# on there — the paths must be explicit. A standalone clone with neither
# still resolves via nim's default nimblepath (`nimble install regex`).
QT_PC_REGEX_SRC := $(QT_PC_SELF_DIR)/../nim-regex/src
QT_PC_CONSUMER_PATHS ?= $(QT_PC_SELF_DIR)/../../nimble.paths
ifneq (,$(wildcard $(QT_PC_REGEX_SRC)))
 QT_PC_GEN_PATHS := --path:$(QT_PC_REGEX_SRC) --path:$(QT_PC_SELF_DIR)/../nim-unicodedb/src
else ifneq (,$(wildcard $(QT_PC_CONSUMER_PATHS)))
 QT_PC_GEN_PATHS := $(shell awk -F'"' '/pkgs2\/(regex|unicodedb)-/{print "--path:" $$2}' $(QT_PC_CONSUMER_PATHS))
else
 QT_PC_GEN_PATHS :=
endif

# --- build the executables (nim on PATH; wrapper is dependency-free) ---------
$(QT_PC_WRAPPER): $(QT_PC_SELF_DIR)/src/pkgconfig_wrapper.nim
	@mkdir -p $(QT_PC_BUILD_DIR)
	$(QT_PC_NIM) c -d:release --hints:off --skipParentCfg:on -o:$@ $<

$(QT_PC_GENERATOR): $(QT_PC_SELF_DIR)/src/prl_to_pc.nim
	@mkdir -p $(QT_PC_BUILD_DIR)
	$(QT_PC_NIM) c -d:release --hints:off --skipParentCfg:on $(QT_PC_GEN_PATHS) -o:$@ $<

.PHONY: qt-pkgconfig-tools
qt-pkgconfig-tools: $(QT_PC_WRAPPER) $(QT_PC_GENERATOR)

# --- generate the committed .pc tree ----------------------------------------
# Builds the generator (only here) and (re)creates this kit's committed .pc tree.
# Used manually on a Qt version bump (commit the result) and as the auto path below
# when the tree is missing. Because the generator is built only in this target, a
# normal build (tree present) never compiles it.
# The .pc tree is COMMITTED CONTENT of this repo: when this file runs from a
# read-only nimble store copy, generation must refuse instead of scribbling on
# pinned content — new kits are added from a real checkout and committed.
.PHONY: qt-pkgconfig-generate
ifneq (,$(QT_PC_STORE_COPY))
qt-pkgconfig-generate:
	@echo "qt-pkgconfig.mk ERROR: this prl-to-pc copy is a read-only nimble store copy —" >&2; \
	 echo "refusing to generate a Qt .pc tree into it (kit '$(QT_PC_KIT)', $(QT_PCFILEDIR))." >&2; \
	 echo "Develop prl-to-pc (in status-desktop: 'nim develop status.nims prl-to-pc'), run" >&2; \
	 echo "'make qt-pkgconfig-generate' against the checkout, and commit the new tree upstream." >&2; \
	 exit 1
else
qt-pkgconfig-generate: $(QT_PC_GENERATOR)
	@echo "[prl-to-pc] generating Qt .pc for '$(QT_PC_KIT)' from $(QT_PC_PREFIX)"
	"$(QT_PC_GENERATOR)" generate "$$($(QMAKE) -query QT_INSTALL_LIBS)" "$(QT_PC_SELF_DIR)"
endif

# Aggregate prerequisite for the nim build: ensure the wrapper, plus this kit's .pc.
# The .pc dependency is added ONLY when the committed tree is absent (decided at parse
# time via QT_PC_HAVE_PC), so the common case pulls in just the wrapper and the
# generator is never built or even considered.
.PHONY: qt-pkgconfig
ifeq (,$(QT_PC_HAVE_PC))
qt-pkgconfig: $(QT_PC_WRAPPER) qt-pkgconfig-generate
else
qt-pkgconfig: $(QT_PC_WRAPPER)
endif

# --- export the pkg-config environment (all internal; nothing for the caller) -
export PKG_CONFIG_PREFIX_OVERRIDE := Qt*=$(QT_PC_PREFIX)
ifneq ($(strip $(QT_PC_ARCH)),)
 export PKG_CONFIG_ARCH := $(QT_PC_ARCH)
endif
ifeq ($(strip $(PKG_CONFIG_PATH)),)
 export PKG_CONFIG_PATH := $(QT_PCFILEDIR)
else
 export PKG_CONFIG_PATH := $(QT_PCFILEDIR)$(QT_PC_PATHSEP)$(PKG_CONFIG_PATH)
endif
export PATH := $(QT_PC_BUILD_DIR):$(PATH)

endif # QT_PKGCONFIG_MK_INCLUDED
