/*
 * A vlen datatype caches the file its data lives in. A dataset's datatype is
 * cached on dataset->shared and reused by every handle on that dataset, so once
 * the handle that created it closes, the cached pointer is stale.
 * H5T_patch_vlen_file() repairs it on every read -- but only when the vlen is
 * the *top-level* type. Here it is a compound member, so the repair never
 * fires, and H5Dread follows the pointer into a destroyed H5F_t:
 *
 *   H5T__conv_vlen -> H5T__vlen_disk_isnull -> H5F_addr_decode
 *       == f->shared->sizeof_addr, and f->shared is NULL
 *
 * Segfaults every time on hdf5 2.0.0 and 2.2.0. Swap the dataset's type for a
 * bare vlen string (make_vlen_str() alone, no compound) and it does not.
 *
 *   make && ./vlen_minimal            # or: cc vlen_minimal.c -lhdf5
 *
 * Under AddressSanitizer (`make asan`, needs a libhdf5 built with
 * -fsanitize=address AND HDF5_ENABLE_USING_MEMCHECKER=ON so its free lists stop
 * recycling the freed struct) it is reported as a textbook use-after-free, and
 * the three stacks land on three lines of this file:
 *
 *   ERROR: AddressSanitizer: heap-use-after-free ... READ of size 8
 *     H5F_addr_decode          H5Fint.c:3077
 *     H5T__vlen_disk_isnull    H5Tvlen.c:764
 *     H5T__conv_vlen           H5Tconv_vlen.c:365
 *     H5T__conv_struct_opt     H5Tconv_compound.c:861
 *     H5Dread                  <- the read through `db`, below
 *   freed by thread T0 here:
 *     H5F__dest                H5Fint.c:1683
 *     H5Fclose                 <- the H5Fclose(a) below
 *   previously allocated by thread T0 here:
 *     H5F__new / H5F_open      <- the H5Fopen that produced `a`
 *
 * Without the memchecker flag the same bug surfaces as a NULL dereference
 * instead (f->shared == NULL on a recycled H5F_t), which is harder to read.
 */

#include <hdf5.h>
#include <stdint.h>
#include <stdio.h>

typedef struct {
    int32_t i;
    char   *s;
} rec_t;

int main(void)
{
    const char *path = "/tmp/vlen_minimal.h5";
    rec_t       row  = {0, "x"};
    hsize_t     dims[1] = {1};

    /* compound { int32 i; vlen-string s } -- the datatype from the issue */
    hid_t str = H5Tcopy(H5T_C_S1);
    H5Tset_size(str, H5T_VARIABLE);
    hid_t dt = H5Tcreate(H5T_COMPOUND, sizeof(rec_t));
    H5Tinsert(dt, "i", HOFFSET(rec_t, i), H5T_NATIVE_INT32);
    H5Tinsert(dt, "s", HOFFSET(rec_t, s), str);

    /* one row, actually written: an unwritten dataset does not reproduce */
    hid_t space = H5Screate_simple(1, dims, NULL);
    hid_t f     = H5Fcreate(path, H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
    hid_t d     = H5Dcreate2(f, "rows", dt, space, H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    H5Dwrite(d, dt, H5S_ALL, H5S_ALL, H5P_DEFAULT, &row);
    H5Dclose(d);
    H5Fclose(f);

    hid_t a  = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
    hid_t da = H5Dopen2(a, "rows", H5P_DEFAULT); /* must stay open, or the cached
                                                  * datatype is evicted below */
    hid_t b  = H5Fopen(path, H5F_ACC_RDONLY, H5P_DEFAULT);
    hid_t db = H5Dopen2(b, "rows", H5P_DEFAULT); /* inherits da's cached datatype */

    H5Dclose(da);
    H5Fclose(a); /* destroys the file that datatype still points at */

    rec_t out;
    H5Dread(db, dt, H5S_ALL, H5S_ALL, H5P_DEFAULT, &out); /* SIGSEGV */

    /* Only reached on a libhdf5 that repairs nested vlens. Tidying up matters
     * here: leaving vlen data unreclaimed can fault in HDF5's own atexit
     * teardown, which looks like the bug but is not it. */
    printf("no crash: i=%d s=%s\n", (int)out.i, out.s);
    H5Treclaim(dt, space, H5P_DEFAULT, &out);
    H5Dclose(db);
    H5Fclose(b);
    H5Sclose(space);
    H5Tclose(dt);
    H5Tclose(str);
    return 0;
}
