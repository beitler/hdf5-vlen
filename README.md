# A stale file pointer in libhdf5's nested vlen datatypes

Reading a dataset whose datatype contains a **variable-length member below the
top level** segfaults, if the handle that first opened the dataset has since
closed while another handle keeps it open.

Originally reported as a threading crash
([h5py#2920](https://github.com/h5py/h5py/issues/2920)). It is not a threading
bug — threads only reach the required state by accident. Everything below is
single-process and single-threaded, and deterministic.

Affects HDF5 **2.0.0** and **2.2.0** (both release tags), in C and through h5py,
at `-O0` and `RelWithDebInfo`, with `HDF5_ENABLE_THREADSAFE` both `ON` and `OFF`.
Nothing here has been submitted upstream; this is local analysis.

## The reproducer

`vlen_minimal.py` — 10 lines through h5py:

```python
a = h5py.File(path, "r")
da = a["rows"]  # must stay referenced, or the cached datatype is evicted
b = h5py.File(path, "r")
db = b["rows"]  # inherits the datatype cached by `da`
a.close()       # destroys the file that datatype still points at
db[:]           # SIGSEGV
```

`vlen_minimal.c` — the same thing against libhdf5 directly, for reporting it
without h5py in the picture (`cc vlen_minimal.c -lhdf5`).

The dataset's type is `compound { int32 i; vlen-string s }`, one row, written.
Two things are required and easy to lose when shortening this:

- **the row must actually be written** — an unwritten dataset of the same type
  does not reproduce, because the conversion never reaches a real blob;
- **`da` must stay bound.** The cached datatype hangs off `dataset->shared`, so
  if A's dataset handle is released before B opens the dataset, the entry is
  evicted and B builds a fresh one. Writing step 1 as `a["rows"][:]` — letting
  the Dataset be a temporary — does not reproduce.

## Why it happens

A vlen datatype stores the file its data lives in. `H5T_set_loc()` stamps it
when the dataset is opened, recursing into compound members and array base
types:

```c
/* H5Dint.c:1748 */  H5T_set_loc(dataset->shared->type, H5F_VOL_OBJ(...), H5T_LOC_DISK)
/* H5Tvlen.c:307 */  dt->shared->u.vlen.file = file;
/* H5Tvlen.c:310 */  H5T_own_vol_obj(dt, file);      /* takes a refcount */
```

1. `dataset->shared` is cached and reused, so B's open does **not** call
   `H5T_set_loc` again — verified under gdb, it fires on A's open and not on
   B's. The stored pointer keeps naming A's file object.

2. The reference from `H5T_own_vol_obj` pins the `H5VL_object_t` **wrapper**, not
   the file behind it. `H5Fclose` destroys the `H5F_t` regardless
   (`f->shared = NULL`, H5Fint.c:1680), leaving the type holding a live wrapper
   around a dead file. At the crash, gdb shows exactly that:

   ```
   vlen member's file wrapper   = 0x5555555c6970
     wrapper->rc                = 4        <- not freed
     wrapper->data (the H5F_t)  = 0x5555555c4380
     owned_vol_obj on the type  = 0x5555555c6970
     ((H5F_t *)data)->shared    = (nil)    <- file was destroyed
   ```

3. libhdf5 has a repair for this and runs it on every read — but it only ever
   matches a *top-level* vlen:

   ```c
   /* H5T.c:7369, in H5T_patch_vlen_file, called from H5Dio.c:1069 */
   if ((dt->shared->type == H5T_VLEN) && dt->shared->u.vlen.file != file)
       dt->shared->u.vlen.file = file;
   ```

   A compound's top-level type is `H5T_COMPOUND`, so it never fires and the
   nested member is never repaired. gdb, on every read:
   `[patch] dt->shared->type=6 -> fires?=0` (6 = `H5T_COMPOUND`, 9 = `H5T_VLEN`).

   **That guard is the bug.** `H5T_set_loc()` recurses when it *sets* the
   pointer; `H5T_patch_vlen_file()` does not recurse when it *repairs* it.

4. The conversion then follows the stale pointer, and `H5F_addr_decode`
   evaluates `H5F_SIZEOF_ADDR(f)` — i.e. `f->shared->sizeof_addr` — on a `NULL`
   `f->shared`:

   ```
   #0  H5F_addr_decode (f=0x5555555c4380)  H5Fint.c:3077
   #1  H5VL__native_blob_specific          H5VLnative_blob.c:159
   #4  H5T__vlen_disk_isnull               H5Tvlen.c:764
   #5  H5T__conv_vlen                      H5Tconv_vlen.c:365
   #7  H5T__conv_struct_opt                H5Tconv_compound.c:861
       ... H5T_convert -> H5D__scatgath_read -> H5D__contig_read -> H5D__read -> H5Dread
   ```

### Under AddressSanitizer

With libhdf5 built `-fsanitize=address` **and**
`HDF5_ENABLE_USING_MEMCHECKER=ON` — the second flag matters, because HDF5's
internal free lists otherwise recycle the freed `H5F_t`, the read lands on live
memory, and the sanitizer sees nothing — it is a textbook use-after-free whose
three stacks land on three lines of the reproducer:

```
==ERROR: AddressSanitizer: heap-use-after-free, READ of size 8
    #0 H5F_addr_decode            src/H5Fint.c:3077
    #4 H5T__vlen_disk_isnull      src/H5Tvlen.c:764
    #5 H5T__conv_vlen             src/H5Tconv_vlen.c:365
    #7 H5T__conv_struct_opt       src/H5Tconv_compound.c:861
   #17 H5Dread                    src/H5D.c:1049
   #18 main                       vlen_minimal.c   <- the read through handle B

0x5070000005e0 is located 16 bytes inside of 72-byte region
freed by thread T0 here:
    #2 H5F__dest                  src/H5Fint.c:1683
   #12 H5Fclose                   src/H5F.c:1040
   #13 main                       vlen_minimal.c   <- H5Fclose(a)

previously allocated by thread T0 here:
    #1 H5F__new                   src/H5Fint.c:1138
    #2 H5F_open                   src/H5Fint.c:1995 <- H5Fopen -> a
```

Without the memchecker flag the same bug appears as a NULL dereference on a
recycled `H5F_t`, which reads as a puzzle rather than a diagnosis.

## What triggers it, and what doesn't

Deterministic, 3 runs each:

| dataset datatype | vlen reachable? | result |
| --- | --- | --- |
| compound `{int32, vlen str}` | via member | SIGSEGV 3/3 |
| compound `{int32, vlen int32}` | via member | SIGSEGV 3/3 |
| `array[3]` of vlen str | via array base | SIGSEGV 3/3 |
| compound `{int32, array[2] of vlen str}` | two levels down | SIGSEGV 3/3 |
| top-level vlen str | it *is* the type | clean 3/3 |
| compound `{int32, char[80]}` | no vlen | clean 3/3 |

Two rows carry the argument. The **top-level vlen** is equally vlen, equally
stale and equally reused — but `type == H5T_VLEN` holds, so the repair fires.
The **array** row has no compound anywhere, so the gap is about nesting in
general: a fix has to recurse, not special-case compounds.

**Possibly the same hazard for references, not demonstrated.**
`H5T__ref_set_loc()` caches a file pointer in exactly the same shape
(`dt->shared->u.atomic.u.r.file = file` plus `H5T_own_vol_obj`, H5Tref.c:228),
`H5T__ref_obj_disk_isnull()` resolves the file from it the same way, and there is
**no patch function for references at all** — only `H5T_patch_vlen_file` and
`H5T_patch_file` (which patches a committed type's `oloc`, not this). But object
references, region references and a compound with a reference member all ran
clean 3/3 through the same sequence, so this is a structural concern without a
reproducer.

## How it presents in practice

Threads reach the same state by accident — one thread closes the handle that
created the cached datatype while another still holds the dataset open — which
is how this surfaced as h5py#2920. Two consequences for anyone triaging it from
a threading report:

- `HDF5_ENABLE_THREADSAFE=ON` does not help, and neither does an external mutex
  around each individual API call (h5py's `phil` is exactly that). There is no
  race to serialise away.
- Single-threaded code is spared only because closing the *last* handle evicts
  `dataset->shared`, so the next open rebuilds the datatype. Any single-threaded
  program that keeps a second handle open across a close hits it too — which is
  all the reproducer does.

## Building it

Dependencies are git submodules pinned to release tags — nothing is downloaded
from a tarball or PyPI:

| submodule | tag |
| --- | --- |
| `third_party/hdf5-2.0.0` | `2.0.0` (the version h5py wheels bundle) |
| `third_party/hdf5-2.2.0` | `2.2.0` (current release) |
| `third_party/h5py` | `3.16.0` |

```sh
make submodules      # git submodule update --init --depth 1
make                 # 4 C binaries: {2.0.0,2.2.0} x {plain,asan}
make venvs           # one venv per hdf5 version, h5py built from the submodule
make patched         # both versions + the patch: libs, binaries and venvs
make run             # all of the above, then ./run-all.sh
```

`make patched` applies the patch in a `git worktree` of *each* submodule — same
pinned commit, same object store, nothing re-downloaded, and the submodules stay
pristine however a build ends (verified: 0 modified files after a full build).
`make sources` creates those worktrees on their own, which the CI workflow does
serially before starting parallel builds.

`make ctest VER=...` runs HDF5's own regression suite against a chosen build.

The installed libraries take their source tree as an *order-only* prerequisite,
so recreating a worktree does not invalidate an already-built library — which is
what lets CI restore `prefix/` from cache and skip all four builds. The
consequence locally is that editing the patch does not trigger a rebuild by
itself: run `make clean-patched` first, which drops only the patched artefacts
and leaves the slow pristine builds alone.

## Results

`make run` builds everything and then checks each outcome: `*-patched` must be
clean, everything else must crash.

```
C binary (libhdf5 build)         result                     expected?
2.0.0-plain                      SIGSEGV                    ok (bug present)
2.0.0-asan                       ASan: heap-use-after-free  ok (bug present)
2.0.0-patched-plain              clean                      ok
2.0.0-patched-asan               clean                      ok
2.2.0-plain                      SIGSEGV                    ok (bug present)
2.2.0-asan                       ASan: heap-use-after-free  ok (bug present)
2.2.0-patched-plain              clean                      ok
2.2.0-patched-asan               clean                      ok

venv (h5py on that libhdf5)      result                     expected?
2.0.0                            SIGSEGV                    ok (bug present)
2.0.0-patched                    clean                      ok
2.2.0                            SIGSEGV                    ok (bug present)
2.2.0-patched                    clean                      ok

per-run output captured in logs/run/
all runs matched expectations

=== sanitizer reports and failure details ===

---- c-2.0.0-asan ----
==...==ERROR: AddressSanitizer: heap-use-after-free on address 0x...
READ of size 8 ...
    #0 ... in H5F_addr_decode src/H5Fint.c:3076
    #1 ... in H5VL__native_blob_specific src/H5VLnative_blob.c:159
    ...
SUMMARY: AddressSanitizer: heap-use-after-free ... in H5F_addr_decode
```

## The fix

`0001-H5T_patch_vlen_file-recurse-into-nested-vlens.patch`, against tag `2.2.0`
(commit `49df1b4`) and applying unchanged to `2.0.0` —
`H5T_patch_vlen_file` is byte-identical in both, only at a different line. One
function in `src/H5T.c`; no header, API or ABI change.

Before — the whole bug is the `== H5T_VLEN` guard:

```c
if ((dt->shared->type == H5T_VLEN) && dt->shared->u.vlen.file != file)
    dt->shared->u.vlen.file = file;
```

After — a guarded switch that walks compound members and array/vlen base types,
mirroring the `H5T_ARRAY` / `H5T_COMPOUND` / `H5T_VLEN` cases of
`H5T_set_loc()`, including its outer `force_conv` gate and its inner
`force_conv && H5T_IS_COMPOSITE` guards. That outer gate also keeps the common
case (a type with no vlen anywhere) to a single test, which matters because this
runs on every `H5Dread`/`H5Dwrite`/`H5Aread`/`H5Awrite`.

Validated:

- every crashing shape above goes from SIGSEGV 3/3 to clean 3/3;
- under ASan, `heap-use-after-free` becomes exit 0 with no findings;
- HDF5's own suite: **2565/2565 pass, identical to the unpatched baseline**,
  including `test_misc39`, which guards the conversion-path-table and VOL
  refcount invariants this change is most likely to disturb;
- no conversion-path-table growth over 40 open/read/close cycles, measured
  against baseline (see the review note below);
- h5py rebuilt from source against the patched library is clean, while the same
  h5py on the pristine library of the same version still crashes.

An alternative worth considering: `H5T_own_vol_obj()` takes a reference on the
`H5VL_object_t` wrapper, which does not keep the underlying `H5F_t` alive. If
that reference held the file open, the cached pointer would stay valid and would
not need repairing at all — which would also cover the reference case above, if
it is real.

### Review of the patch

Six independent reviewers read it against the source.

**Adopted.** The patch originally omitted `H5T_set_loc`'s *outer* `force_conv`
gate while its comment claimed to mirror the guards — inaccurate, and it meant
walking every compound member on every I/O call. The gate is now present, which
also gives the early-out.

**Adopted.** The comment claimed the recursion patches "exactly the subtypes
that were stamped". It does not: `H5T_set_loc` also stamps REFERENCE datatypes
and this function has never repaired those. The comment now says so plainly
instead of overclaiming.

**Checked, did not materialise.** Four reviewers independently flagged the
highest-severity concern: `H5T__vlen_set_loc` always pairs `u.vlen.file = file`
with `H5T_own_vol_obj()`, and `H5F__dest` purges cached conversion paths by
matching `owned_vol_obj` (H5Fint.c:1670 →
`H5T_path_match_find_type_with_volobj`). The patch updates only the pointer, so
nested vlens could in principle diverge and leak path-table entries. Probing
`H5T__get_path_table_npaths()` over 40 open/read/close cycles on the dataset
path — which `test_misc39` does not cover, as it uses attributes — showed no
growth on either build (213 entries throughout, patched identical to baseline).
Combined with `test_misc39` passing, the concern does not reproduce. It is a real asymmetry in the code, but pre-existing
and not made worse here; `H5T_own_vol_obj` also frees the currently-owned object
before taking the new reference, so "just call it too" is not a safe one-liner.

### Not addressed

- **References.** Same shape as the vlen bug, and no patch function for it at
  all — but no reproducer, as above. Out of scope for this fix, which
  deliberately does not change reference behaviour.
- **Fill-value paths.** `H5D__fill_init`/`H5D__fill_refill_vl` (`H5Dfill.c`)
  read and write nested vlens through `dset->shared->type` without ever calling
  `H5T_patch_vlen_file`. That gap is pre-existing and untouched here.
