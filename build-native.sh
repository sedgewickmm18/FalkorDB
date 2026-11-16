#!/bin/bash
# build-native.sh — Build and optionally run FalkorDB natively on Linux.
#
# Replicates what the Docker toolchain image does, but on the host system.
# Tested on Fedora 44 (x86_64) with clang-22, cmake 4+, cargo/rustc 1.82+.
#
# Usage:
#   ./build-native.sh            # build everything, then print run instructions
#   ./build-native.sh --run      # build everything, then start redis-server
#   ./build-native.sh --skip-graphblas   # reuse existing libgraphblas.a
#   ./build-native.sh --skip-redisearch  # reuse existing RediSearch build
#   ./build-native.sh --skip-redis       # skip building redis-server from source
#                                        # (uses the redis/valkey already on PATH)
#
# Environment overrides (all optional):
#   CC, CXX          — compiler to use (default: clang / clang++)
#   REDIS_VERSION    — upstream redis git tag to build (default: 8.6.3)
#   REDIS_PORT       — port to listen on when --run is used (default: 6379)
#   FALKORDB_ARGS    — extra module arguments (default: MAX_QUEUED_QUERIES 25 ...)
#   DATA_DIR         — redis --dir value when --run is used (default: /tmp/falkordb-data)

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
RUN=0
SKIP_GRAPHBLAS=0
SKIP_REDISEARCH=0
SKIP_REDIS=0

for arg in "$@"; do
    case "${arg}" in
        --run)              RUN=1 ;;
        --skip-graphblas)   SKIP_GRAPHBLAS=1 ;;
        --skip-redisearch)  SKIP_REDISEARCH=1 ;;
        --skip-redis)       SKIP_REDIS=1 ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown argument: ${arg}"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CC="${CC:-clang}"
CXX="${CXX:-clang++}"
REDIS_VERSION="${REDIS_VERSION:-8.6.3}"
REDIS_PORT="${REDIS_PORT:-6379}"
DATA_DIR="${DATA_DIR:-/tmp/falkordb-data}"
FALKORDB_ARGS="${FALKORDB_ARGS:-MAX_QUEUED_QUERIES 25 TIMEOUT 1000 RESULTSET_SIZE 10000}"
JOBS="${JOBS:-$(nproc)}"

# Where the built redis-server lands (only used when --skip-redis is NOT set).
REDIS_INSTALL_DIR="${SCRIPT_DIR}/.native/redis-install"
# Where to look for redis-server when using --skip-redis.
SYSTEM_REDIS="$(command -v redis-server 2>/dev/null || true)"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  \033[34m→\033[0m %s\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
bold "=== FalkorDB native build ==="

info "Compiler:     ${CC} / ${CXX}"
"${CC}" --version 2>/dev/null | head -1 | sed 's/^/             /'
info "CMake:        $(cmake --version 2>/dev/null | head -1)"
info "Cargo:        $(cargo --version 2>/dev/null)"
info "Jobs:         ${JOBS}"
echo

# Required tools
for tool in git cmake cargo "${CC}" "${CXX}"; do
    command -v "${tool}" >/dev/null 2>&1 || die "'${tool}' not found — install it first"
done

# Fedora: openssl-devel is needed by Redis/RediSearch. zlib.h is provided by
# zlib-ng (compat headers) on Fedora 44 even without zlib-devel, so only warn
# if zlib.h itself is missing. Warn rather than abort so users on other distros
# can decide for themselves.
if command -v rpm >/dev/null 2>&1; then
    rpm -q openssl-devel >/dev/null 2>&1 || warn "openssl-devel not installed; install it if the Redis build fails"
fi
[ -f /usr/include/zlib.h ] || warn "zlib.h not found; install zlib-devel (or zlib-ng-compat-devel on Fedora) if the build fails"

# Submodule check
if [ -z "$(ls -A "${SCRIPT_DIR}/deps/RediSearch" 2>/dev/null || true)" ]; then
    die "deps/RediSearch is empty. Run:  git submodule update --init --recursive"
fi
if [ -z "$(ls -A "${SCRIPT_DIR}/deps/RediSearch/deps/VectorSimilarity" 2>/dev/null || true)" ]; then
    die "deps/RediSearch/deps/VectorSimilarity is empty. Run:  git submodule update --init --recursive"
fi

# ---------------------------------------------------------------------------
# Step 1 — Build static libomp.a (if the system only ships libomp.so)
# ---------------------------------------------------------------------------
# graph/build.rs links libomp statically when /opt/libomp/lib/libomp.a exists,
# otherwise it falls back to -lomp (dynamic). On Fedora the package libomp-devel
# ships only libomp.so, so we prefer to build the static version so the resulting
# .so has no libomp runtime dependency.
#
# Skip this step if:
#   a) /opt/libomp/lib/libomp.a already exists (built previously), OR
#   b) a LIBOMP_PREFIX env var points at a valid static archive.
LIBOMP_PREFIX="${LIBOMP_PREFIX:-/opt/libomp}"
LIBOMP_A="${LIBOMP_PREFIX}/lib/libomp.a"

if [ -f "${LIBOMP_A}" ]; then
    ok "libomp.a already present at ${LIBOMP_A} — skipping libomp build"
else
    bold "--- Step 1/4: building static libomp ---"
    # Detect the installed clang version so we build libomp from the matching
    # llvm-project tag (same ABI as the compiler on PATH).
    LLVMORG_VERSION=$("${CC}" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "${LLVMORG_VERSION}" ] || die "Cannot detect LLVM version from '${CC} --version'"
    info "Detected LLVM ${LLVMORG_VERSION}"

    # libomp.sh needs write access to the install prefix.
    if [ ! -d "${LIBOMP_PREFIX}" ] && [ "$(id -u)" -ne 0 ]; then
        info "Creating ${LIBOMP_PREFIX} (requires sudo)"
        sudo mkdir -p "${LIBOMP_PREFIX}"
        sudo chown "$(id -u):$(id -g)" "${LIBOMP_PREFIX}"
    fi

    CC="${CC}" CXX="${CXX}" PREFIX="${LIBOMP_PREFIX}" \
        bash "${SCRIPT_DIR}/build/libomp.sh" "${LLVMORG_VERSION}"
    ok "libomp.a installed at ${LIBOMP_A}"
fi
echo

# ---------------------------------------------------------------------------
# Step 2 — Build GraphBLAS + LAGraph
# ---------------------------------------------------------------------------
bold "--- Step 2/4: building GraphBLAS + LAGraph ---"

GRAPHBLAS_INSTALL_PREFIX="${GRAPHBLAS_INSTALL_PREFIX:-/usr/local}"

# Fedora installs to lib64/, Debian/Ubuntu to lib/ — probe both.
_find_graphblas_a() {
    for d in "${GRAPHBLAS_INSTALL_PREFIX}/lib" "${GRAPHBLAS_INSTALL_PREFIX}/lib64"; do
        [ -f "${d}/libgraphblas.a" ] && echo "${d}/libgraphblas.a" && return
    done
}
GRAPHBLAS_A="$(_find_graphblas_a)"

if [ "${SKIP_GRAPHBLAS}" -eq 1 ]; then
    [ -n "${GRAPHBLAS_A}" ] || die "--skip-graphblas set but libgraphblas.a not found under ${GRAPHBLAS_INSTALL_PREFIX}/lib[64]; run without the flag first"
    ok "Skipping GraphBLAS build (--skip-graphblas)"
elif [ -n "${GRAPHBLAS_A}" ]; then
    ok "libgraphblas.a already present at ${GRAPHBLAS_A} — skipping build (pass --skip-graphblas to suppress this message)"
else
    # Newer trees build GraphBLAS/LAGraph via the native-deps crate during
    # `cargo build` (step 5) and no longer carry graphblas.sh. Only run it
    # when it exists (older trees).
    if [ -f "${SCRIPT_DIR}/graphblas.sh" ]; then
        LAGRAPH_INSTALL_DIR="${SCRIPT_DIR}/lagraph_lib"
        CC="${CC}" CXX="${CXX}" \
            GRAPHBLAS_INSTALL_PREFIX="${GRAPHBLAS_INSTALL_PREFIX}" \
            LAGRAPH_INSTALL_DIR="${LAGRAPH_INSTALL_DIR}" \
            LIBOMP_PREFIX="${LIBOMP_PREFIX}" \
            bash "${SCRIPT_DIR}/graphblas.sh"
    else
        warn "graphblas.sh not found — GraphBLAS/LAGraph will be built by"
        warn "native-deps during 'cargo build' (step 5); CC/CXX are exported."
    fi
    # Re-probe after install — cmake may have chosen lib or lib64.
    GRAPHBLAS_A="$(_find_graphblas_a)"
    [ -n "${GRAPHBLAS_A}" ] || die "graphblas.sh completed but libgraphblas.a not found under ${GRAPHBLAS_INSTALL_PREFIX}/lib[64]"
    ok "GraphBLAS + LAGraph built: ${GRAPHBLAS_A}"
fi
echo

# ---------------------------------------------------------------------------
# Step 3 — Build RediSearch static library
# ---------------------------------------------------------------------------
bold "--- Step 3/4: building RediSearch ---"

RS_RELEASE_DIR="${SCRIPT_DIR}/deps/RediSearch/bin"
# Check for any release variant directory that contains the expected archive.
RS_BUILT=0
if [ "${SKIP_REDISEARCH}" -eq 1 ]; then
    RS_BUILT=1
    ok "Skipping RediSearch build (--skip-redisearch)"
else
    # A successful build leaves at least one search-community dir with a .a/.so.
    for variant_dir in "${RS_RELEASE_DIR}"/*/search-community; do
        if [ -d "${variant_dir}" ] && \
           { [ -f "${variant_dir}/redisearch.a" ] || [ -f "${variant_dir}/libredisearch.a" ] || [ -f "${variant_dir}/redisearch.so" ]; }; then
            RS_BUILT=1
            ok "RediSearch already built in ${variant_dir} — skipping (use --skip-redisearch to suppress)"
            break
        fi
    done
fi

if [ "${RS_BUILT}" -eq 0 ]; then
    CC="${CC}" CXX="${CXX}" bash "${SCRIPT_DIR}/redisearch.sh"
    ok "RediSearch built"
fi
echo

# ---------------------------------------------------------------------------
# Step 4 — Build redis-server from source
# ---------------------------------------------------------------------------
bold "--- Step 4/5: building redis-server ---"

if [ "${SKIP_REDIS}" -eq 1 ]; then
    if [ -z "${SYSTEM_REDIS}" ]; then
        die "--skip-redis set but no redis-server found on PATH"
    fi
    REDIS_SERVER="${SYSTEM_REDIS}"
    warn "Using system redis-server: ${REDIS_SERVER}"
    warn "  Note: this may be Valkey or a different Redis fork/version."
    "${REDIS_SERVER}" --version
elif [ -x "${REDIS_INSTALL_DIR}/bin/redis-server" ]; then
    REDIS_SERVER="${REDIS_INSTALL_DIR}/bin/redis-server"
    ok "redis-server already built at ${REDIS_SERVER} — skipping"
    "${REDIS_SERVER}" --version
else
    mkdir -p "${SCRIPT_DIR}/.native"
    REDIS_SRC="${SCRIPT_DIR}/.native/redis-src"
    # Always wipe the source tree before cloning: a prior failed build may have
    # left stale .o files compiled by a different compiler (e.g. clang emitting
    # LLVM IR bitcode), which the current linker (GCC/ld) cannot process.
    rm -rf "${REDIS_SRC}"
    info "Cloning redis ${REDIS_VERSION}..."
    git clone --depth 1 --branch "${REDIS_VERSION}" \
        https://github.com/redis/redis.git "${REDIS_SRC}"

    info "Patching protected-mode default to 0..."
    sed -ri 's!^( *createBoolConfig[(]"protected-mode",.*, *)1( *,.*[)],)$!\10\2!' \
        "${REDIS_SRC}/src/config.c"
    grep -E '^ *createBoolConfig[(]"protected-mode",.*, *0 *,.*[)],$' \
        "${REDIS_SRC}/src/config.c" >/dev/null \
        || die "protected-mode patch failed — check redis version"

    info "Building redis (this takes 1-2 minutes)..."
    # Pass CC/CXX to every make invocation so the compiler is consistent across
    # compilation AND linking. Redis's Makefile auto-detects clang via CC and
    # adjusts flags accordingly; mixing compilers (clang compile + gcc link)
    # produces LLVM IR bitcode .o files that the system linker cannot process.
    make -C "${REDIS_SRC}" -j"${JOBS}" \
        BUILD_TLS=yes BUILD_WITH_MODULES=no \
        CC="${CC}" CXX="${CXX}" \
        all

    make -C "${REDIS_SRC}" \
        CC="${CC}" CXX="${CXX}" \
        PREFIX="${REDIS_INSTALL_DIR}" install
    strip "${REDIS_INSTALL_DIR}/bin/redis-server" \
          "${REDIS_INSTALL_DIR}/bin/redis-cli"
    REDIS_SERVER="${REDIS_INSTALL_DIR}/bin/redis-server"
    ok "redis-server built: $(${REDIS_SERVER} --version)"
fi
echo

# ---------------------------------------------------------------------------
# Step 5 — Build libfalkordb.so
# ---------------------------------------------------------------------------
bold "--- Step 5/5: building libfalkordb.so ---"

cd "${SCRIPT_DIR}"
# CC must be exported too: on this tree GraphBLAS is built by the native-deps
# crate inside `cargo build`, which reads $CC to pick the cmake C compiler.
# Without it cmake falls back to `cc` (GCC on Fedora), and GCC rejects the
# clang-only `-fopenmp=libomp` flag that native-deps forces when the static
# libomp at /opt/libomp is present.
export CC="${CC}"
export CXX="${CXX}"
export LIBOMP_PREFIX="${LIBOMP_PREFIX}"
# graph/build.rs looks up GRAPHBLAS_LIB_DIR; point it at the directory that
# actually holds libgraphblas.a (lib/ on Debian/Ubuntu, lib64/ on Fedora/RHEL).
export GRAPHBLAS_LIB_DIR="$(dirname "${GRAPHBLAS_A}")"

cargo build --release

SO="${SCRIPT_DIR}/target/release/libfalkordb.so"
[ -f "${SO}" ] || die "Build succeeded but ${SO} not found"
ok "Built: ${SO} ($(du -h "${SO}" | cut -f1))"

# Verify the self-containment contract: no dynamic dep on libomp/graphblas/etc.
DEPS="$(ldd "${SO}" | awk '{print $1}' | sort -u)"
if echo "${DEPS}" | grep -qE '^(libomp|libgomp|libgraphblas|liblagraph|liblagraphx|libredisearch|libVectorSimilarity)'; then
    warn "WARNING: libfalkordb.so has unexpected dynamic dependencies:"
    echo "${DEPS}" | grep -E '^(libomp|libgomp|libgraphblas|liblagraph|liblagraphx|libredisearch|libVectorSimilarity)'
fi
echo

# ---------------------------------------------------------------------------
# Done — print run instructions or start the server
# ---------------------------------------------------------------------------
mkdir -p "${DATA_DIR}"

if [ "${RUN}" -eq 1 ]; then
    bold "=== Starting FalkorDB on port ${REDIS_PORT} ==="
    info "Module:   ${SO}"
    info "Redis:    ${REDIS_SERVER}"
    info "Data dir: ${DATA_DIR}"
    info "Args:     ${FALKORDB_ARGS}"
    echo
    # exec so signals go directly to redis-server
    exec "${REDIS_SERVER}" \
        --protected-mode no \
        --port "${REDIS_PORT}" \
        --dir "${DATA_DIR}" \
        --loadmodule "${SO}" ${FALKORDB_ARGS}
else
    bold "=== Build complete ==="
    echo
    echo "To start FalkorDB:"
    echo
    echo "  ${REDIS_SERVER} \\"
    echo "    --protected-mode no \\"
    echo "    --port ${REDIS_PORT} \\"
    echo "    --dir ${DATA_DIR} \\"
    echo "    --loadmodule ${SO} \\"
    echo "    ${FALKORDB_ARGS}"
    echo
    echo "Or just run:  $0 --run"
    echo
fi
