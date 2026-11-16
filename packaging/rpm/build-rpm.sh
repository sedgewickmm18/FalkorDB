#!/bin/bash
# build-rpm.sh — build the falkordb RPM from an already-built libfalkordb.so.
#
# Usage:
#   ./packaging/rpm/build-rpm.sh [--version X.Y.Z] [--so PATH] [--redis PATH] [--build]
#
#   --version  package version (default: version from Cargo.toml)
#   --so       path to libfalkordb.so (default: target/release/libfalkordb.so)
#   --redis    upstream redis-server to bundle (default: .native/redis-install/bin/redis-server)
#   --build    run ./build-native.sh first if the .so or redis-server is missing
#
# Output: target/rpm/RPMS/<arch>/falkordb-<version>-1.<dist>.<arch>.rpm

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_DIR="${ROOT}/packaging/rpm"
TOPDIR="${ROOT}/target/rpm"
SO="${ROOT}/target/release/libfalkordb.so"
VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "${ROOT}/Cargo.toml" | head -1)"
REDIS="${ROOT}/.native/redis-install/bin/redis-server"
BUILD=0

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --so)      SO="$2"; shift 2 ;;
        --redis)   REDIS="$2"; shift 2 ;;
        --build)   BUILD=1; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v rpmbuild >/dev/null || { echo "rpmbuild not found (dnf install rpm-build)" >&2; exit 1; }

if { [ ! -f "${SO}" ] || [ ! -x "${REDIS}" ]; } && [ "${BUILD}" -eq 1 ]; then
    "${ROOT}/build-native.sh"
fi
[ -f "${SO}" ] || { echo "${SO} not found; build it first or pass --build" >&2; exit 1; }

[ -x "${REDIS}" ] || { echo "${REDIS} not found; run build-native.sh or pass --redis" >&2; exit 1; }

rm -rf "${TOPDIR}"
mkdir -p "${TOPDIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp "${SO}" "${TOPDIR}/SOURCES/libfalkordb.so"
cp "${REDIS}" "${TOPDIR}/SOURCES/redis-server"
cp "${SRC_DIR}"/falkordb.{service,conf,sysusers} "${TOPDIR}/SOURCES/"

rpmbuild -bb "${SRC_DIR}/falkordb.spec" \
    --define "_topdir ${TOPDIR}" \
    --define "fdb_version ${VERSION}"

find "${TOPDIR}/RPMS" -name '*.rpm'
