# JuliaSysimage

How a Julia project runs jobs on the octopus condor cluster.

Every dependency of the project is compiled into one system image. Jobs are submitted on octopus itself, so the image is uploaded once per Manifest, not with every job.

A job then needs no registry, downloads or precompilation. It starts in about 1–2 min, most of that compiling first calls, and peaks at the run's own memory. Without an image, every job and every restart downloads and precompiles about 200 packages (200–530 s) and needs an 8 G memory request for that spike.

## One-time setup (per machine)

- `ln -s <this folder>/bin/jlsysimage ~/.local/bin/jlsysimage`, with `~/.local/bin` on the `PATH`.
- `ssh octopus` must work non-interactively (an ssh alias, port 2935). Override the host and remote folder with `JLS_HOST` and `JLS_ROOT`.

## New project

1. **Pin local packages by commit.** For example `Pkg.add(url="~/.julia/dev/UniformCMPSKit", rev="<commit>")`. No vendored copies.
2. **Build:** `jlsysimage build`. This writes `remote/sysimage/deps-<h>.{so,so.zst}` and `deps-<h>_depot/`, where `h` comes from the Manifest's hash. Gitignore `/remote/sysimage/deps-*`.
3. **Write a test script,** `remote/sysimage/workload.jl`: a few seconds of the project's real calls.
4. **Test:** copy `test.submit.example` to `test.submit`, then run `jlsysimage sync`, then `jlsysimage submit test.submit`.
5. **Check the test.** Every job's stderr must show:
   - the same Julia commit as `julia -e 'print(Base.GIT_VERSION_INFO.commit_short)'` locally (otherwise the image won't load);
   - `Exit status: 0`;
   - a depot of a few hundred KB.
6. **Real submit files** follow the template:
   - `executable = job.sh` and `arguments = <image>.so <script> <args>`;
   - inputs: Project, Manifest, `src`, the scripts, `<image>.so.zst` and `<image>_depot`;
   - **`transfer_output_files` set explicitly**;
   - requests measured as below.

Day to day: `jlsysimage sync`, then `jlsysimage submit <file>`, then later `jlsysimage fetch`. Fetch pulls `condor_data/` and `condorlogs/` back. Query the queue with `ssh octopus condor_q`.

Changed the Manifest? Run `jlsysimage build`, then `jlsysimage prune`, which deletes the old local images; the next `sync` removes them on octopus too.

## Sizing requests

Measure; never guess.

- **Memory:** `job.sh` writes `Maximum resident set size` to every job's stderr. For finished jobs, `ssh octopus condor_history <cluster> -af MemoryUsage CpusUsage RemoteWallClockTime RemoteUserCpu` gives the same. Set `request_memory` to about 1.5× the peak of a real-size run, at least 2 G. The test script is too small to size from.
- **CPUs:** time a fixed number of iterations at 1, 2 and 4 BLAS threads (`BLAS.set_num_threads`). Request more than one CPU only if it pays.
  - DipolarGas at D = 32: 0.32, 0.32 and 0.34 s per iteration at 1, 2 and 4 threads.
  - `CpusUsage` well below `request_cpus` means the request is wasted.
  - Smaller requests match more slots and count less against your user priority.
- Recheck when the bond dimension or model changes, and record the numbers in the project.

## Rules

- **Build alone.** It takes about 3 min and peaks at about 11 GB, with one CPU target (haswell, which runs on every node and the laptop). PackageCompiler's multi-target default was OOM-killed at 16.4 GB.
- **No `--workload`.** Baking a precompile workload into the image made a run 40% slower under Julia 1.12: GC 44% vs 17% of the time, 41 vs 7 full sweeps, the same allocation. Neither the heap-size hint nor more GC threads helped. Without it, first calls compile on the node, about 1 min per job.
- **Rebuild** when the Manifest changes (`jlsysimage name` differs from the image) or when the nodes' Julia changes (re-run the test).
- **octopus `/home` is a shared disk**: 35 users, and your home is world-readable. A project there should be about 100 MB: sources plus the compressed image (83 MB for DipolarGas). Outputs only as named in `transfer_output_files`.
- **Compressed image:** zstd -19 shrinks it 6.5×. Each job's input transfer takes about 2 s; unpacking takes 2–40 s depending on the node's disk.

Measured 2026-10-28 (DipolarGas, Julia 1.12.7 6d172b025e4): nodes peps (skylake-avx512), erquaf (skylake-avx512) and tensorval (AMD Zen 5) all pass. The test script ran 88–115 s, peaking at 1.3 GB; a real D = 32 run peaks at 1.07 GB.
