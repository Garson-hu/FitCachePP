#!/bin/bash
#SBATCH -A gen008
#SBATCH -J p1b_overhead
#SBATCH -p batch
#SBATCH -q debug
#SBATCH -N 1
#SBATCH -t 00:55:00
#SBATCH -C nvme
#SBATCH -o /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/benchmarks/results/frontier/p1b_overhead_%j.out

module reset
module swap PrgEnv-cray PrgEnv-gnu
module load miniforge3
module unload darshan-runtime 2>/dev/null

export LD_LIBRARY_PATH=/sw/frontier/spack-envs/base/opt/cray-sles15-zen3/cce-15.0.0/mercury-2.0.1-4okvpnqnw7aejnvzoevcnu5h6x7hb7a7/lib:/ccs/home/ghu4/log4c-1.2.4/install/lib:${LD_LIBRARY_PATH:-}

srun -N 1 -n 1 -c 16 bash /lustre/orion/gen008/proj-shared/ghu4/FitCachePP/scripts/p1b/p1b_overhead_bench.sh
