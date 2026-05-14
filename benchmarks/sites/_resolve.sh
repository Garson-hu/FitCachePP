# benchmarks/sites/_resolve.sh
#
# Source me from every launcher script BEFORE doing anything site-specific.
# I resolve the active site from $FITPP_SITE (default: arc) and source the
# matching $FITPP_REPO/benchmarks/sites/<site>.sh, which sets every FITPP_*
# path/value the rest of the launcher uses.
#
# Usage from a launcher (relative to this file's location is fine):
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../sites/_resolve.sh"
#
# After sourcing, you can rely on $FITPP_REPO, $FITPP_BUILD_DIR, etc.
#
# To pick a non-default site, set FITPP_SITE before invoking sbatch:
#   FITPP_SITE=frontier sbatch ...

# Default site if caller didn't set one. Keep this empty-string-safe so a
# launcher that runs interactively without FITPP_SITE still works.
FITPP_SITE="${FITPP_SITE:-arc}"

# Find sites/ directory. Two situations:
#   (a) launcher sourced us with SCRIPT_DIR set; SITES_DIR is alongside it
#   (b) caller didn't set SCRIPT_DIR; fall back to the dir holding _resolve.sh
if [ -n "${SITES_DIR:-}" ]; then
    : # caller already pointed us at the sites dir
else
    SITES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

SITE_CONFIG="${SITES_DIR}/${FITPP_SITE}.sh"

if [ ! -f "$SITE_CONFIG" ]; then
    echo "[sites] ERROR: no config for FITPP_SITE=${FITPP_SITE}" >&2
    echo "[sites]   looked for: $SITE_CONFIG" >&2
    echo "[sites]   known sites: $(ls "$SITES_DIR"/*.sh 2>/dev/null | xargs -n1 basename | sed 's/\.sh$//' | grep -v '^_' | tr '\n' ' ')" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$SITE_CONFIG"

# Sanity-check the must-have variables. Any one of these being unset means the
# site file is incomplete and we'd get a confusing failure later.
_required_vars=(
    FITPP_REPO
    FITPP_BUILD_DIR
    FITPP_SERVER_BIN
    FITPP_CLIENT_LIB
    FITPP_RESULTS_ROOT
    FITPP_PFS_DATA_ROOT
    FITPP_LOCAL_CACHE_ROOT
    FITPP_PFS_REGISTRY_ROOT
    FITPP_COSMOFLOW_DIR
    FITPP_COSMOFLOW_DATA_DEFAULT
    FITPP_PYTHON_TF
    FITPP_MERCURY_LIB_DIR
    FITPP_MERCURY_PKGCONFIG_DIR
    FITPP_MERCURY_BIN_DIR
    FITPP_LOG4C_LIB_DIR
    FITPP_LOG4C_PKGCONFIG_DIR
    FITPP_SLURM_PARTITION
)
_missing=()
for _v in "${_required_vars[@]}"; do
    if [ -z "${!_v:-}" ]; then
        _missing+=("$_v")
    fi
done
if [ ${#_missing[@]} -gt 0 ]; then
    echo "[sites] ERROR: site ${FITPP_SITE} did not set: ${_missing[*]}" >&2
    echo "[sites]   edit $SITE_CONFIG to define them" >&2
    exit 1
fi

# Optional but commonly-used envs — set defaults if site didn't.
export FITPP_SERVERS_PER_NODE_DEFAULT="${FITPP_SERVERS_PER_NODE_DEFAULT:-4}"
export FITPP_GPUS_PER_NODE_DEFAULT="${FITPP_GPUS_PER_NODE_DEFAULT:-1}"
export FITPP_LAUNCHER_KIND="${FITPP_LAUNCHER_KIND:-horovodrun}"
export FITPP_MODULE_LOADS="${FITPP_MODULE_LOADS:-}"

# Compose PATH / LD_LIBRARY_PATH / PKG_CONFIG_PATH additions for FitCache.
# Caller can extend further but these need to be present.
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}:${FITPP_LOG4C_PKGCONFIG_DIR}:${FITPP_MERCURY_PKGCONFIG_DIR}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:${FITPP_LOG4C_LIB_DIR}:${FITPP_MERCURY_LIB_DIR}"
# Frontier-style sites supply $FITPP_PYTHON_TF_BIN_DIR for PATH; arc-style
# sites can leave it unset and we'll derive it from the python path.
if [ -z "${FITPP_PYTHON_TF_BIN_DIR:-}" ] && [ -n "${FITPP_PYTHON_TF:-}" ]; then
    FITPP_PYTHON_TF_BIN_DIR="$(dirname "$FITPP_PYTHON_TF")"
fi
export PATH="${FITPP_PYTHON_TF_BIN_DIR}:${FITPP_MERCURY_BIN_DIR}:${PATH}"

# Module loads (Frontier needs this; arc leaves it empty).
if [ -n "$FITPP_MODULE_LOADS" ]; then
    eval "$FITPP_MODULE_LOADS"
fi

echo "[sites] resolved FITPP_SITE=${FITPP_SITE}  (repo=$FITPP_REPO)"
