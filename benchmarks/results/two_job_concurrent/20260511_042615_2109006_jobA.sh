#!/bin/bash
#SBATCH -p rtx4060ti16g
#SBATCH -w c70
#SBATCH -t 1-00:00:00
#SBATCH -J FITPP_con_A
#SBATCH -o /home/ghu4/hvac/FitCachePP/benchmarks/results/two_job_concurrent/20260511_042615_2109006_jobA-%j.out

export FitCache_CROSS_JOB=1
export FitCache_CLUSTER_REGISTRY_DIR=/mnt/beegfs/ghu4/fitcachepp_registry_two_job_concurrent/20260511_042615_2109006
export FitCache_HEARTBEAT_SEC=10
export FitCache_SERVER_COUNT=4
export SERVERS_PER_NODE=4
export FitCache_DRAM_PATH=/mnt/local/ghu4/fitcachepp_dram_20260511_042615_2109006
export FitCache_NVME_PATH=/mnt/local/ghu4/fitcachepp_nvme_20260511_042615_2109006
export FitCache_DRAM_CAPACITY=107374182400
export FitCache_NVME_CAPACITY=536870912000
export FitCache_DATA_DIR=/mnt/beegfs/ghu4/hvac/cosmoUniverse_2019_05_4parE_tf_v2_mini/train_61440/train/
export BBPATH=/mnt/local/ghu4/fitcachepp_nvme_20260511_042615_2109006
export FitCache_LOG_LEVEL=500
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib
export PATH=/home/ghu4/hvac/rlibrary/miniconda3/envs/hvac_tf/bin:/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH
export RESULTS_DIR=/home/ghu4/hvac/FitCachePP/benchmarks/results/two_job_concurrent
exec /home/ghu4/hvac/FitCachePP/benchmarks/cosmoflow/PDSW_FITPP_inner.sh
