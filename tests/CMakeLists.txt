add_executable(basic_test basic_test.c )
add_executable(test_open_close test_open_close.c)

# TPDS extension Phase-1 smoke test: exercises FNV/HRW/dataset_id/registry
# without touching Mercury, so it can run on any host (no MPI/Slurm needed).
include(FindPkgConfig)
pkg_check_modules(LOG4C REQUIRED IMPORTED_TARGET log4c)

add_executable(test_cross_job_smoke
    test_cross_job_smoke.cpp
    ${CMAKE_SOURCE_DIR}/src/fitcache_cross_job.cpp
    ${CMAKE_SOURCE_DIR}/src/fitcache_dataset_id.cpp
    ${CMAKE_SOURCE_DIR}/src/fitcache_cluster_registry.cpp
    ${CMAKE_SOURCE_DIR}/src/fitcache_logging.c)
# fitcache_logging.h #errors out if neither symbol is defined; we pick CLIENT
# arbitrarily — the test exercises shared utility code that doesn't depend
# on which side is actually using it at runtime.
target_compile_definitions(test_cross_job_smoke PRIVATE FitCache_CLIENT)
target_include_directories(test_cross_job_smoke PRIVATE
    ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_cross_job_smoke PRIVATE
    pthread PkgConfig::LOG4C)
