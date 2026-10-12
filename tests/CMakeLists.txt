add_executable(basic_test basic_test.c )
add_executable(test_open_close test_open_close.c)
add_executable(harness_read_files harness_read_files.c)

# Cross-job extension smoke: exercises FNV / HRW / dataset_id / registry /
# sidecar metadata / subscriber-lease / sibling-cache refresh / heartbeat
# self-heal — does not touch Mercury, so it runs on any host.
include(FindPkgConfig)
pkg_check_modules(LOG4C REQUIRED IMPORTED_TARGET log4c)

add_executable(test_cross_job_smoke
    test_cross_job_smoke.cpp
    ${CMAKE_SOURCE_DIR}/src/cross_job/fitcache_cross_job.cpp
    ${CMAKE_SOURCE_DIR}/src/cross_job/fitcache_dataset_id.cpp
    ${CMAKE_SOURCE_DIR}/src/cross_job/fitcache_cluster_registry.cpp
    ${CMAKE_SOURCE_DIR}/src/cross_job/fitcache_persistent_meta.cpp
    ${CMAKE_SOURCE_DIR}/src/client/fitcache_mmap_tracker.cpp
    ${CMAKE_SOURCE_DIR}/src/common/fitcache_logging.c)
# fitcache_logging.h #errors out if neither symbol is defined; pick CLIENT
# arbitrarily — the test exercises shared utility code that doesn't depend
# on which side is actually using it at runtime.
target_compile_definitions(test_cross_job_smoke PRIVATE FitCache_CLIENT)
target_include_directories(test_cross_job_smoke PRIVATE
    ${CMAKE_SOURCE_DIR}/src/client
    ${CMAKE_SOURCE_DIR}/src/server
    ${CMAKE_SOURCE_DIR}/src/comm
    ${CMAKE_SOURCE_DIR}/src/cross_job
    ${CMAKE_SOURCE_DIR}/src/common)
target_link_libraries(test_cross_job_smoke PRIVATE
    pthread PkgConfig::LOG4C)

# CXL tier pool: store / read / seek / restart recovery, no Mercury. Runs
# against a regular directory by default; pass a famfs directory as argv[1]
# (and configure with -DFITCACHE_FAMFS=ON) to run it on CXL memory.
add_executable(test_cxl_pool
    test_cxl_pool.cpp
    ${CMAKE_SOURCE_DIR}/src/server/fitcache_cxl_pool.cpp
    ${CMAKE_SOURCE_DIR}/src/common/fitcache_logging.c)
target_compile_definitions(test_cxl_pool PRIVATE FitCache_CLIENT)
target_include_directories(test_cxl_pool PRIVATE
    ${CMAKE_SOURCE_DIR}/src/server
    ${CMAKE_SOURCE_DIR}/src/common)
target_link_libraries(test_cxl_pool PRIVATE pthread PkgConfig::LOG4C)
if(FITCACHE_FAMFS)
    target_sources(test_cxl_pool PRIVATE
        ${CMAKE_SOURCE_DIR}/vendor/famfs/thpool/thpool.c
        ${CMAKE_SOURCE_DIR}/vendor/famfs/thpool/gettid_shim.c)
    target_compile_definitions(test_cxl_pool PRIVATE FITCACHE_HAVE_FAMFS)
    target_include_directories(test_cxl_pool PRIVATE
        ${CMAKE_SOURCE_DIR}/vendor/famfs/include
        ${CMAKE_SOURCE_DIR}/vendor/famfs/thpool)
    target_link_libraries(test_cxl_pool PRIVATE
        ${CMAKE_SOURCE_DIR}/vendor/famfs/lib/liblibfamfs.a
        /usr/local/lib64/libfuse3.so.4 yaml uuid z daxctl)
endif()
