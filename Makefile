# Build the reproducer against every libhdf5 we care about.
#
# Sources of truth are git submodules, pinned to release tags:
#   third_party/hdf5-2.0.0   (the version h5py wheels bundle)
#   third_party/hdf5-2.2.0   (current release)
#   third_party/h5py         (3.16.0, built from source against each of the above)
#
#   make                 # 4 C binaries: {2.0.0,2.2.0} x {plain,asan}
#   make venvs           # one venv per version, h5py built from source
#   make patched         # both versions + the patch: libs, binaries and venvs
#   make run             # build everything and print the results table
#   make clean           # drop build/ bin/ prefix/ (keeps submodules)
#   make clean-patched   # drop only the patched artefacts, e.g. after editing the patch
#
# ASan builds set HDF5_ENABLE_USING_MEMCHECKER=ON as well. That matters: HDF5's
# internal free lists otherwise recycle the freed H5F_t, so the bad read lands
# on live memory and the sanitizer reports nothing.

TOP        := $(CURDIR)
VERSIONS   ?= 2.0.0 2.2.0
VARIANTS   ?= plain asan
SRC        := $(TOP)/vlen_minimal.c
PYREPRO    := $(TOP)/vlen_minimal.py
PATCH      := $(TOP)/0001-H5T_patch_vlen_file-recurse-into-nested-vlens.patch
JOBS       ?= $(shell nproc)
PYTHON_VER ?= 3.14

export TMPDIR := $(TOP)/build/tmp
$(shell mkdir -p $(TMPDIR))

CFLAGS    ?= -O1 -g -Wall -Wextra
ASANFLAGS := -fsanitize=address -fno-omit-frame-pointer

CMAKE_COMMON := \
  -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DBUILD_TESTING=OFF \
  -DHDF5_BUILD_TOOLS=OFF -DHDF5_BUILD_EXAMPLES=OFF -DHDF5_BUILD_UTILS=OFF \
  -DHDF5_BUILD_HL_LIB=ON -DHDF5_BUILD_CPP_LIB=OFF -DHDF5_BUILD_FORTRAN=OFF

CMAKE_ASAN := \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_FLAGS="$(ASANFLAGS) -g" \
  -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address" \
  -DCMAKE_SHARED_LINKER_FLAGS="-fsanitize=address" \
  -DHDF5_ENABLE_USING_MEMCHECKER=ON

CMAKE_PLAIN := -DCMAKE_BUILD_TYPE=RelWithDebInfo

BINS  := $(foreach v,$(VERSIONS),$(foreach a,$(VARIANTS),bin/vlen_minimal-$(v)-$(a)))
# A stamp file, not the directory: a directory target left behind by a failed
# install looks up to date to make, and you get a venv without h5py in it.
VENVS := $(foreach v,$(VERSIONS),.venv-$(v)/.built)

.PHONY: all venvs patched run clean distclean submodules
all: $(BINS)
venvs: $(VENVS)

submodules:
	git submodule update --init --depth 1 --recursive
	@git submodule status

# --- per (version, variant) rules -------------------------------------------
#
# $(1) = label, $(2) = variant, $(3) = source tree, $(4) = extra cmake,
# $(5) = source-tree prerequisite (empty for the pristine submodules)
#
# $(5) is ORDER-ONLY (after the |) on purpose. The worktree has to exist before
# we can build from it, but its timestamp must not invalidate an installed
# library: CI restores prefix/ from cache and recreates the worktrees in the
# same run, so a normal prerequisite would make every patched build miss the
# cache. What the library actually depends on -- the pinned commit and the
# patch -- is covered by the cache key in .github/workflows/reproducer.yml.
# Locally, that means editing the patch does not trigger a rebuild by itself;
# use `make clean-patched` first.
define HDF5_BUILD
prefix/hdf5-$(1)-$(2)/lib/libhdf5.so: $(if $(5),| $(5))
	@test -f $(3)/CMakeLists.txt || { echo "missing $(3) -- run: make submodules"; exit 1; }
	@mkdir -p logs
	cmake -S $(3) -B build/hdf5-$(1)-$(2) \
	    -DCMAKE_INSTALL_PREFIX=$(TOP)/prefix/hdf5-$(1)-$(2) \
	    $(CMAKE_COMMON) $(4) > logs/cmake-$(1)-$(2).log 2>&1
	cmake --build build/hdf5-$(1)-$(2) -j$(JOBS) > logs/build-$(1)-$(2).log 2>&1
	cmake --install build/hdf5-$(1)-$(2) >> logs/build-$(1)-$(2).log 2>&1

bin/vlen_minimal-$(1)-$(2): $(SRC) prefix/hdf5-$(1)-$(2)/lib/libhdf5.so
	@mkdir -p bin
	$$(CC) $(CFLAGS) $(if $(filter asan,$(2)),$(ASANFLAGS),) \
	    -I$(TOP)/prefix/hdf5-$(1)-$(2)/include -o $$@ $(SRC) \
	    -L$(TOP)/prefix/hdf5-$(1)-$(2)/lib \
	    -Wl,-rpath,$(TOP)/prefix/hdf5-$(1)-$(2)/lib -lhdf5 \
	    $(if $(filter asan,$(2)),$(ASANFLAGS),)
endef

$(foreach v,$(VERSIONS),\
  $(eval $(call HDF5_BUILD,$(v),plain,$(TOP)/third_party/hdf5-$(v),$(CMAKE_PLAIN),)) \
  $(eval $(call HDF5_BUILD,$(v),asan,$(TOP)/third_party/hdf5-$(v),$(CMAKE_ASAN),)))

# --- venvs: h5py compiled against our libhdf5, not the bundled wheel --------
# setuptools writes its build tree *inside* the source directory, so two venv
# builds sharing one h5py checkout collide ("File exists: .../h5py-3.16.0
# .dist-info"). Each venv therefore builds from its own git worktree of the
# submodule -- same pinned commit, same object store, nothing re-downloaded.
define H5PY_WORKTREE
$(TOP)/build/h5py-$(1)-src/setup.py:
	@mkdir -p $(TOP)/build
	git -C third_party/h5py worktree add --detach $(TOP)/build/h5py-$(1)-src HEAD
endef

define VENV_BUILD
# The h5py checkout is order-only for the same reason as above; the venv is
# rebuilt when the library it links against changes, which is the real input.
.venv-$(1)/.built: prefix/hdf5-$(1)-plain/lib/libhdf5.so | $(TOP)/build/h5py-$(1)-src/setup.py
	@mkdir -p $(TMPDIR)
	rm -rf .venv-$(1)
	uv venv --python $(PYTHON_VER) .venv-$(1)
	HDF5_DIR=$(TOP)/prefix/hdf5-$(1)-plain \
	    uv pip install --python .venv-$(1) --no-cache numpy $(TOP)/build/h5py-$(1)-src
	@.venv-$(1)/bin/python -c "import h5py, os; h5py.File; \
	  libs = sorted({l.split()[-1] for l in open(f'/proc/{os.getpid()}/maps') if 'libhdf5' in l}); \
	  print('  h5py', h5py.__version__, 'on hdf5', h5py.version.hdf5_version); \
	  [print('  loaded:', l) for l in libs]"
	@touch $$@
endef
$(foreach v,$(VERSIONS),\
  $(eval $(call H5PY_WORKTREE,$(v))) \
  $(eval $(call VENV_BUILD,$(v))))

# --- the patched libraries, for validating the fix --------------------------
#
# The patch is applied in a git worktree of each submodule, not in the submodule
# itself: same pinned commit, same object store, nothing re-downloaded, and the
# submodules stay pristine however a build ends. It also makes "<ver>-patched" an
# ordinary label, so it goes through the same rules as everything else.
#
# The same patch applies to both releases -- H5T_patch_vlen_file is byte-identical
# in 2.0.0 and 2.2.0, only at a different line -- so both get patched builds.
PATCHED_VERSIONS := $(foreach v,$(VERSIONS),$(v)-patched)

define PATCHED_SRC_RULE
$(TOP)/build/$(1)-patched-src/CMakeLists.txt:
	@test -f $(PATCH) || { echo "no patch at $(PATCH)"; exit 1; }
	@mkdir -p $(TOP)/build
	git -C third_party/hdf5-$(1) worktree add --detach $(TOP)/build/$(1)-patched-src HEAD
	git -C $(TOP)/build/$(1)-patched-src apply $(PATCH)
	@echo "patched worktree for $(1); submodule untouched"
endef

$(foreach v,$(VERSIONS),\
  $(eval $(call PATCHED_SRC_RULE,$(v))) \
  $(eval $(call HDF5_BUILD,$(v)-patched,plain,$(TOP)/build/$(v)-patched-src,$(CMAKE_PLAIN),$(TOP)/build/$(v)-patched-src/CMakeLists.txt)) \
  $(eval $(call HDF5_BUILD,$(v)-patched,asan,$(TOP)/build/$(v)-patched-src,$(CMAKE_ASAN),$(TOP)/build/$(v)-patched-src/CMakeLists.txt)) \
  $(eval $(call H5PY_WORKTREE,$(v)-patched)) \
  $(eval $(call VENV_BUILD,$(v)-patched)))

PATCHED_BINS  := $(foreach v,$(PATCHED_VERSIONS),$(foreach a,$(VARIANTS),bin/vlen_minimal-$(v)-$(a)))
PATCHED_VENVS := $(foreach v,$(PATCHED_VERSIONS),.venv-$(v)/.built)

# Create every git worktree the build needs -- patched hdf5 sources and a
# per-venv h5py checkout. Run this serially before starting parallel builds:
# `git worktree add` takes a repository lock, and two lanes creating worktrees
# at once can fail on it.
.PHONY: sources
sources: $(foreach v,$(VERSIONS),$(TOP)/build/$(v)-patched-src/CMakeLists.txt) \
         $(foreach v,$(VERSIONS) $(PATCHED_VERSIONS),$(TOP)/build/h5py-$(v)-src/setup.py)

.PHONY: patched-src
patched-src: sources

.PHONY: patched
patched: $(PATCHED_BINS) $(PATCHED_VENVS)

# --- extra validation ------------------------------------------------------
# HDF5's own regression suite, for the patched tree vs the pristine one. Needs
# its own build because it wants BUILD_TESTING and the tools.
# Usage: make ctest VER=2.2.0     /     make ctest VER=2.2.0-patched
VER ?= 2.2.0
CTEST_SRC = $(if $(filter %-patched,$(VER)),$(TOP)/build/$(patsubst %-patched,%,$(VER))-patched-src,$(TOP)/third_party/hdf5-$(VER))
.PHONY: ctest
ctest:
	@mkdir -p logs
	@test -f $(CTEST_SRC)/CMakeLists.txt || { echo "no source for VER=$(VER)"; exit 1; }
	cmake -S $(CTEST_SRC) -B build/ctest-$(VER) \
	    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF \
	    -DBUILD_TESTING=ON -DHDF5_BUILD_TOOLS=ON -DHDF5_BUILD_EXAMPLES=OFF \
	    -DHDF5_BUILD_UTILS=OFF -DHDF5_BUILD_HL_LIB=ON -DHDF5_BUILD_CPP_LIB=OFF \
	    -DHDF5_BUILD_FORTRAN=OFF > logs/cmake-ctest-$(VER).log 2>&1
	cmake --build build/ctest-$(VER) -j$(JOBS) > logs/build-ctest-$(VER).log 2>&1
	cd build/ctest-$(VER) && ctest -j$(JOBS) 2>&1 | tail -3

# --- run everything ---------------------------------------------------------
run: all $(VENVS)
	@./run-all.sh

# Drop just the patched artefacts, so an edited patch is picked up. The
# pristine libraries -- the slow half of a rebuild -- are left alone.
.PHONY: clean-patched
clean-patched:
	rm -rf $(foreach v,$(VERSIONS),\
	          build/$(v)-patched-src build/hdf5-$(v)-patched-* \
	          prefix/hdf5-$(v)-patched-* .venv-$(v)-patched) \
	       $(foreach v,$(PATCHED_VERSIONS),bin/vlen_minimal-$(v)-plain bin/vlen_minimal-$(v)-asan)
	@for v in $(VERSIONS); do git -C third_party/hdf5-$$v worktree prune 2>/dev/null || true; done

clean:
	rm -rf build bin prefix logs
	@for v in $(VERSIONS); do git -C third_party/hdf5-$$v worktree prune 2>/dev/null || true; done
	@git -C third_party/h5py worktree prune 2>/dev/null || true

distclean: clean
	rm -rf $(foreach v,$(VERSIONS) $(PATCHED_VERSIONS),.venv-$(v))
