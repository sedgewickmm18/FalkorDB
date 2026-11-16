# Building FalkorDB natively: GraphBLAS and the `-fopenmp=libomp` failure

This note documents why an older FalkorDB checkout builds natively while a
recent one fails inside GraphBLAS with:

```
cc: error: unrecognized command-line option '-fopenmp=libomp'; did you mean '-fopenmp-simd'?
gmake[2]: *** [CMakeFiles/GraphBLAS_static.dir/build.make:107: ...PreJIT/GB_jit__*.c.o] Error 1
```

**TL;DR — this is not a GraphBLAS bug and needs no GraphBLAS patch.** The
failure is a compiler mix-up: `-fopenmp=libomp` is a clang-only flag spelling,
and the build that failed was driving GraphBLAS's cmake with **GCC** (`cc`),
not clang. Fix: `export CC=clang CXX=clang++` (or run `./build-native.sh`,
which now exports `CC` itself — see below).

## How the two trees differ

| | older tree (`FalkorDB.Strix`) | recent tree |
|---|---|---|
| GraphBLAS source | cloned upstream tag `v10.5.0` by `graphblas.sh` | pinned git submodule `deps/GraphBLAS` |
| Who runs cmake | `graphblas.sh`, step 2 of `build-native.sh` | the `native-deps` crate, inside `cargo build --release` (step 5) |
| Compiler selection | explicit: `CC=clang bash graphblas.sh` → `-DCMAKE_C_COMPILER=clang` | `Toolchain::detect()` reads `$CC` from cargo's environment |
| OpenMP wiring | same as below | same logic, ported to `native-deps/src/toolchain.rs` |
| PreJIT kernels | vendored set in `build/graphblas/PreJIT/` | same mechanism, larger vendored set (regenerate via `native-deps prejit`) |

Both trees force the same OpenMP configuration whenever
`/opt/libomp/lib/libomp.a` exists (built by `build/libomp.sh` in step 1 so the
final `libfalkordb.so` embeds libomp statically instead of depending on
`libgomp.so.1`):

```cmake
-DOpenMP_C_FLAGS=-fopenmp=libomp        # clang-only spelling!
-DOpenMP_CXX_FLAGS=-fopenmp=libomp
-DOpenMP_omp_LIBRARY=/opt/libomp/lib/libomp.a
```

Clang accepts `-fopenmp=libomp`. GCC only accepts plain `-fopenmp` (or
`-fopenmp=libgomp`), hence the error — it surfaces on the first `PreJIT/*.c`
kernel because those compile with the OpenMP flags applied.

## Why the recent tree picked GCC

`build-native.sh` passed `CC=clang` to each sub-script individually but, before
`cargo build --release`, it exported only `CXX` and `LIBOMP_PREFIX` — **not
`CC`**. On the older tree that was harmless because `graphblas.sh` received
`CC` explicitly. On the recent tree the GraphBLAS cmake invocation happens
inside cargo via `native-deps`, which saw no `$CC`, so cmake fell back to its
own detection: `/usr/lib64/ccache/cc` → GCC. You can confirm this in a failed
build tree's `CMakeCache.txt`:

```
CMAKE_C_COMPILER:FILEPATH=/usr/lib64/ccache/cc     ← GCC, should be clang
OpenMP_C_FLAGS:UNINITIALIZED=-fopenmp=libomp
```

Failed native-deps build trees are kept under
`~/.cache/falkordb/native-deps/graphblas/<key>/.build`.

## Fixes applied in this tree

1. **`build-native.sh`** now does `export CC` (alongside `CXX`) before
   `cargo build`, and tolerates the absence of `graphblas.sh` (the recent tree
   builds GraphBLAS/LAGraph via `native-deps` in step 5, so step 2 is vestigial
   there).
2. **`native-deps/src/toolchain.rs`** fails fast with a clear message when the
   static libomp is detected but the resolved C compiler is GCC, instead of
   dying mid-build on the first PreJIT kernel.
3. **`native-deps/src/recipes/graphblas.rs`** passes
   `-DCMAKE_INSTALL_LIBDIR=lib`. On Fedora, cmake's GNUInstallDirs defaults to
   `lib64/`, so the freshly-built archive installed to
   `<cache-entry>/lib64/libgraphblas.a` while the recipe (and the LAGraph
   recipe, which hardcodes `{prefix}/lib/libgraphblas.a`) looked in `lib/` —
   the build succeeded and then panicked with "GraphBLAS build finished but
   …/lib/libgraphblas.a is missing". The old `graphblas.sh` avoided this by
   probing both `lib` and `lib64`; `native-deps` instead pins a flat `lib/`
   layout inside its cache entries.
4. **`native-deps/src/recipes/redisearch.rs`** ports the two SVS mitigations
   the old `redisearch.sh` carried and the port dropped: it passes
   `-DUSE_SVS=OFF` (opt back in with `BUILD_INTEL_SVS_OPT=1`) and guards the
   unconditional `#include "VecSim/algorithms/svs/svs_tiered.h"` in
   `tiered_factory.h` behind `#if HAVE_SVS`. Without these, cmake defaults
   `USE_SVS=ON`, tries to fetch Intel's SVS (shared-lib tarball or a full
   FetchContent source build — both fail offline), and VecSim then fails with
   `'svs/index/vamana/dynamic_index.h' file not found`. SVS is an optional
   vector-index optimization; vector search works without it.

## If you still want a GraphBLAS-side workaround

If you must drive GraphBLAS's cmake with GCC on a host that also has
`/opt/libomp`, either drop the `-DOpenMP_*` overrides and let
`find_package(OpenMP)` auto-detect (`OpenMp::Auto` in native-deps terms), or
use GCC's spelling: `-DOpenMP_C_FLAGS=-fopenmp`. The FalkorDB-native build
does neither — it pins clang, because the static archives are ABI-tied to the
compiler that built them and the self-contained-`.so` contract is validated
against the clang + static-libomp combination.

## Strix Halo notes

Strix Halo (AMD Ryzen AI Max, x86_64) needs no architecture-specific changes
here: the failure above is compiler-selection, not ISA. Just make sure the
toolchain is the clang you intend (`CC=clang CXX=clang++`), and that
`/opt/libomp` was built by step 1 with the matching clang.
