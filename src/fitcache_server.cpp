#include <csignal>   // signal
#include <cstdlib>   // exit
#include <atomic>
#include <iostream>
#include <string.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "fitcache_timer.h"
#include "fitcache_comm.h"
#include "fitcache_data_mover_internal.h"
#include "fitcache_cluster_registry.h"
#include "fitcache_cross_job.h"

#define FitCache_SERVER 1

extern "C" {
#include "fitcache_logging.h"
}

#include "fitcache_cache_policy.h"

__thread bool tl_disable_redirect = false;
uint32_t fitcache_server_count = 0;
static std::atomic<bool> g_running{true};

// Background thread that maintains the cluster-registry heartbeat for this
// server when cross-job mode is enabled. Sleeps in `FitCache_HEARTBEAT_SEC`
// chunks; calls `registry_gc_stale()` once per heartbeat to clean up
// crashed peers.
static void *fitcache_heartbeat_fn(void *arg)
{
    int rank = *static_cast<int *>(arg);
    int interval_sec = 30;
    if (const char *v = std::getenv("FitCache_HEARTBEAT_SEC")) {
        int n = std::atoi(v);
        if (n > 0) interval_sec = n;
    }
    while (g_running) {
        // Wake up every second so shutdown is responsive even at long intervals.
        for (int i = 0; i < interval_sec && g_running; ++i) sleep(1);
        if (!g_running) break;
        fitcache::registry_heartbeat(rank);
        fitcache::registry_gc_stale();
        // Emit a periodic cross-job counters snapshot. Cheap; one L4C_INFO
        // line per heartbeat. The snapshot includes per-counter delta vs.
        // the previous emit, which is what experiment analysis usually wants.
        if (fitcache::cross_job_enabled()) {
            fitcache::log_cross_job_stats(rank);
        }
    }
    return nullptr;
}

struct fitcache_lookup_arg {
	hg_class_t *hg_class;
	hg_context_t *context;
	hg_id_t id;
	hg_addr_t addr;
};

void signal_exit(int signum)
{
    std::cerr << "\n[fitcache_server] Caught signal " << signum
              << ", exiting...\n";

    g_running = false;

    // Final cross-job counters dump so post-run analysis has the totals even
    // when the process is signalled before the next heartbeat fires.
    if (fitcache::cross_job_enabled()) {
        fitcache::log_cross_job_stats(fitcache_server_rank);
    }

    std::exit(0);
}

int fitcache_start_comm_server(void)
{
    FitCache_TIMING("HvacServer_start_comm_server_Total");
    HG_Set_log_level("DEBUG");

    // !--- BEGIN: Write PID to file with server ID ---
    pid_t current_pid = getpid();
    const char* pid_file_path = "/tmp/fitcache_server.pid";
    
    FILE* pid_f = fopen(pid_file_path, "w");
    if (pid_f) {
        fprintf(pid_f, "%d\n", current_pid);
        fclose(pid_f);
        L4C_INFO("Server (PID: %d) wrote PID to %s", current_pid, pid_file_path);
    } else {
        L4C_ERR("Server (PID: %d) FAILED to write PID to %s. errno: %d", current_pid, pid_file_path, errno);
        // Decide if this is a fatal error
    }
    // !--- END: Write PID to file ---

    /* Start the data mover before anything else */
    pthread_t fitcache_data_mover_tid;
    {
        // FitCache_TIMING("HvacServer_data_mover_thread_create");
        if (pthread_create(&fitcache_data_mover_tid, NULL, fitcache_data_mover_fn, NULL) != 0){
            L4C_FATAL("Failed to initialized mecury progress thread\n");
        }
    }

    L4C_INFO("Starting FitCache comm server");
    /* True means we're a listener */
    fitcache_init_comm(true);

    /* Post our address */
    fitcache_comm_list_addr();

    /* Register basic RPC */
    fitcache_rpc_register_server();
    fitcache_open_rpc_register_server();
    fitcache_close_rpc_register_server();
    fitcache_seek_rpc_register_server();

    // // ! Register the trigger RPC
    // fitcache_trigger_srv_print_stats_rpc_register();

    // === Cross-job extension: cluster registry registration + peer-lookup
    //     RPC handler. Gated by FitCache_CROSS_JOB=1; single-job runs skip
    //     this entirely so behaviour is bit-identical to IPDPS. ===
    static pthread_t heartbeat_tid;
    static int       heartbeat_rank;
    if (fitcache::cross_job_enabled()) {
        if (fitcache::registry_init() == 0) {
            fitcache_peer_lookup_rpc_register_server();

            fitcache::ServerEndpoint self;
            self.rank      = fitcache_server_rank;
            // The Mercury self-addr was captured by fitcache_comm_list_addr()
            // immediately above; reuse it so cross-job clients can route
            // straight from the registry without rereading .ports.cfg.
            self.addr      = fitcache_comm_get_self_addr_string();
            self.node_uuid = "";  // registry fills with /etc/machine-id
            const char *jobid = std::getenv("SLURM_JOBID");
            self.jobid     = jobid ? jobid : "";
            self.live      = true;
            if (self.addr.empty()) {
                L4C_WARN("registry: self addr is empty after fitcache_comm_list_addr; "
                         "cross-job clients won't be able to route to this server");
            }
            fitcache::registry_register_server(self);

            heartbeat_rank = fitcache_server_rank;
            if (pthread_create(&heartbeat_tid, NULL,
                               fitcache_heartbeat_fn, &heartbeat_rank) != 0) {
                L4C_WARN("Failed to start cluster-registry heartbeat thread");
            }

            // Cross-job durability: scan tier directories for sidecars left
            // behind by a previous server lifetime and rebuild path_cache_map
            // so peer-job lookups against this server return has=1 instead
            // of has=0. No-op on first-ever start.
            int restored = fitcache_data_mover_restore_from_sidecars();
            if (restored > 0) {
                L4C_INFO("Cross-job startup: restored %d cached files from "
                         "sidecar metadata", restored);
            }

            // Cross-job eviction: start the background reaper that enforces
            // FitCache_EVICT_HIGH_WM / FitCache_EVICT_LOW_WM watermarks.
            static pthread_t reaper_tid;
            fitcache_eviction_reaper_running.store(true);
            if (pthread_create(&reaper_tid, NULL,
                               fitcache_eviction_reaper_fn, NULL) != 0) {
                L4C_WARN("Failed to start cross-job eviction reaper thread");
                fitcache_eviction_reaper_running.store(false);
            }
        } else {
            L4C_WARN("FitCache_CROSS_JOB=1 but registry_init failed; "
                     "running in single-job mode");
        }
    }

    while (g_running)
        sleep(1);

    if (fitcache::cross_job_enabled()) {
        fitcache_eviction_reaper_running.store(false);
        fitcache::registry_deregister_server(fitcache_server_rank);
    }

    return EXIT_SUCCESS;
}


int main(int argc, char **argv)
{
    std::signal(SIGINT,  signal_exit);  
    std::signal(SIGTERM, signal_exit);  
    std::signal(SIGKILL, signal_exit);  
    FitCache_TIMING("HvacServer_main_Total");
    
    int l_error = 0;

    // Quick and dirty for prototype
    if (argc < 2)
    {
        fprintf(stderr, "Please supply server count\n");
        exit(-1);
    }

    fitcache_server_count = atoi(argv[1]);

    fitcache_init_logging();
    L4C_INFO("Server process starting up");
    //int *pid_server = NULL;
    //PMI_Get_rank(pid_server);
    //L4C_INFO("PMI Rank ID: %d \n", pid_server);  
    fitcache_start_comm_server();
    L4C_INFO("FitCache Server process shutting down");
    return (l_error);
}
