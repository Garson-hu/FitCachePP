# Site configuration

This directory holds per-system configuration for running FitCachePP benchmarks.

The C++ source and build of FitCachePP is portable; what differs across systems
is everything around it — SLURM partition name and account, PFS dataset paths,
local cache device paths, Python environment paths, Mercury / log4c library
locations, and module loads.

## How it works

Every benchmark launcher script sources `benchmarks/sites/_resolve.sh` early.
That helper looks at the `FITPP_SITE` environment variable (default: `arc`) and
sources `benchmarks/sites/${FITPP_SITE}.sh`, which sets all `FITPP_*` paths
the rest of the scripts need.

```
benchmarks/sites/
  README.md         (this file)
  _resolve.sh       (sourced by launchers; picks the right site file)
  arc.sh            (current local cluster: NCSU ARC)
  frontier.sh       (ORNL Frontier — template; user fills in real paths)
```

## Adding a new site

1. Copy `frontier.sh` to `<your_site>.sh`.
2. Fill in every `FITPP_*` variable for your system. Search the file for the
   string `TODO` — each one marks a path or value you must set before the
   scripts will run.
3. Submit with `FITPP_SITE=<your_site> sbatch ...`.

## Variables every site config must define

See `frontier.sh` for the full list with descriptions. The required minimum is
the repo and build paths, the external training-script paths
(CosmoFlow / Megatron / DINOv2), Python interpreter paths, Mercury and log4c
library paths, PFS dataset roots, local cache device roots, SLURM partition
and account, and module-load lines for any clusters with environment modules
(Frontier requires this; the local ARC cluster does not).

## What is NOT site-specific

Anything inside `src/` or `tests/` — the C++ build is portable. The wrapper
scripts that contain SLURM `#SBATCH` directives use site-specific values only
through env vars set by the site config, never hardcoded paths.
