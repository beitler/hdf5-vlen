"""
A vlen datatype caches the file its data lives in. A dataset's datatype is
cached on `dataset->shared` and reused by every handle on that dataset, so once
the handle that created it closes, the cached pointer is stale.
`H5T_patch_vlen_file()` repairs it on every read -- but only when the vlen is
the *top-level* type. Here it is a compound member, so the repair never fires.

Segfaults every time on h5py 3.16.0 with hdf5 2.0.0 and 2.2.0.
Change the dtype to a plain `h5py.string_dtype()` and it does not.
"""

import sys
import tempfile

import h5py
import numpy as np

# flush: without it this line is lost when the process dies under a pipe.
print(f"h5py {h5py.__version__} / hdf5 {h5py.version.hdf5_version} / "
      f"python {sys.version.split()[0]} / numpy {np.__version__}", flush=True)

path = tempfile.NamedTemporaryFile(suffix=".h5", delete=False).name

with h5py.File(path, "w") as f:
    d = f.create_dataset("rows", (1,), dtype=[("i", np.int32), ("s", h5py.string_dtype())])
    d[0] = (0, "x")

a = h5py.File(path, "r")
da = a["rows"]  # must stay referenced, or the cached datatype is evicted
b = h5py.File(path, "r")
db = b["rows"]  # inherits the datatype cached by `da`
a.close()       # destroys the file that datatype still points at
db[:]           # SIGSEGV
