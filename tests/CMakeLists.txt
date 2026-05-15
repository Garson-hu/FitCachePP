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
