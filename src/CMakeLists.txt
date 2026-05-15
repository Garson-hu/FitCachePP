# Source tree post-2026-05-14 reorganization:
#   client/    — LD_PRELOAD client library
#   server/    — fitcache_server binary
#   comm/      — Mercury RPC infrastructure shared by client + server
#   cross_job/ — cross-job extension (new in TPDS): registry, HRW routing,
#                sidecar metadata, dataset identity
#   common/    — shared headers (logging, timing, internal constants)
include(FindPkgConfig)
pkg_check_modules(MERCURY REQUIRED IMPORTED_TARGET mercury)
pkg_check_modules(LOG4C REQUIRED IMPORTED_TARGET log4c)

# Subdirs are kept on the include path so existing `#include "fitcache_X.h"`
# lines (no path prefix) keep working without per-file edits.
set(FITCACHE_INCLUDE_DIRS
    ${CMAKE_CURRENT_SOURCE_DIR}/client
    ${CMAKE_CURRENT_SOURCE_DIR}/server
    ${CMAKE_CURRENT_SOURCE_DIR}/comm
    ${CMAKE_CURRENT_SOURCE_DIR}/cross_job
    ${CMAKE_CURRENT_SOURCE_DIR}/common
)

# Cross-job extension sources, shared by client (lookup path) and server
# (RPC handler / registry / data mover).
set(FITCACHE_CROSS_JOB_SOURCES
    cross_job/fitcache_cross_job.cpp
    cross_job/fitcache_dataset_id.cpp
    cross_job/fitcache_cluster_registry.cpp
    cross_job/fitcache_persistent_meta.cpp
)

# ---- libfitcache_client.so (LD_PRELOAD'd into training Python) ----
add_library(fitcache_client SHARED
    client/fitcache_client.cpp
    client/wrappers.c
    client/fitcache_multi_source_read.cpp
    client/fitcache_real_functions.cpp
    comm/fitcache_comm.cpp
    comm/fitcache_comm_client.cpp
    common/fitcache_logging.c
    ${FITCACHE_CROSS_JOB_SOURCES})
target_compile_definitions(fitcache_client PUBLIC FitCache_CLIENT)
target_compile_definitions(fitcache_client PUBLIC FitCache_PRELOAD)
target_include_directories(fitcache_client PRIVATE
    ${CMAKE_SOURCE_DIR}/include
    ${FITCACHE_INCLUDE_DIRS})
target_link_libraries(fitcache_client PRIVATE pthread dl PkgConfig::LOG4C PkgConfig::MERCURY)

# ---- fitcache_server (the daemon) ----
# Note: fitcache_cache_policy.cpp remains unlinked (dead code, preserved per
# implementation_notes.md "Pre-existing code issues found while building").
add_executable(fitcache_server
    server/fitcache_server.cpp
    server/fitcache_data_mover.cpp
    comm/fitcache_comm.cpp
    comm/fitcache_comm_server.cpp
    common/fitcache_logging.c
    ${FITCACHE_CROSS_JOB_SOURCES})
target_compile_definitions(fitcache_server PUBLIC FitCache_SERVER)
target_include_directories(fitcache_server PRIVATE
    ${CMAKE_SOURCE_DIR}/include
    ${FITCACHE_INCLUDE_DIRS})
target_link_libraries(fitcache_server PRIVATE pthread PkgConfig::LOG4C rt PkgConfig::MERCURY)

install(TARGETS fitcache_client DESTINATION lib)
install(TARGETS fitcache_server DESTINATION bin)
