# CondorTools

How a Julia project runs jobs on the octopus condor cluster.

Every dependency of the project is compiled into one system image. Jobs are submitted on octopus itself, so the image is uploaded once per Manifest, not with every job.

A job then needs no registry, downloads or precompilation. It starts in about 1–2 min, most of that compiling first calls, and peaks at the run's own memory. Without an image, every job and every restart downloads and precompiles about 200 packages (200–530 s) and needs an 8 G memory request for that spike.

## One-time setup (per machine)

- `ln -s <this folder>/bin/condortools ~/.local/bin/condortools`, with `~/.local/bin` on the `PATH`.
- `ssh octopus` must work non-interactively (an ssh alias, port 2935). Override the host and remote folder with `CT_HOST` and `CT_ROOT`.

## New project

1. **Pin local packages by commit.** For example `Pkg.add(url="~/.julia/dev/UniformCMPSKit", rev="<commit>")`.
2. **Build:** `condortools build`. This writes into `remote/sysimage/`:
   - `deps-<h>.so.zst`, the compressed image (`zstd -d --long=27` restores the `.so`; the build deletes the uncompressed one), and `deps-<h>_depot/`, where `h` comes from the Manifest's hash. Gitignore `/remote/sysimage/deps-*`.
   - `image.sub` (`IMAGE = remote/sysimage/deps-<h>`). Commit it. Submit files `include` it, so a new image needs no edits there.
3. **Write a test script,** `remote/sysimage/workload.jl`: a few seconds of the project's real calls.
4. **Test:** copy `test.submit.example` into the project (e.g. `remote/condor/test.submit`), then run `condortools sync`, then `condortools submit remote/condor/test.submit`.
5. **Check the test.** Every job's stderr must show:
   - the same Julia commit as `julia -e 'print(Base.GIT_VERSION_INFO.commit_short)'` locally (otherwise the image won't load);
   - `Exit status: 0`;
   - a depot of a few hundred KB.
6. **Real submit files** follow the template:
   - `include : remote/sysimage/image.sub`;
   - inputs: Project, Manifest, `src`, `scripts`, `job.sh`, `$(IMAGE).so.zst` and `$(IMAGE)_depot`;
   - `preserve_relative_paths = FALSE`: files land in the sandbox root, directories keep their contents;
   - the image is passed to `job.sh` as `$Fn(IMAGE).so`;
   - a project wrapper script, if any, calls `./job.sh "$IMAGE" <script> <args>`, with `IMAGE=$Fn(IMAGE).so` in `environment`;
   - **`transfer_output_files` set explicitly**;
   - requests measured as below.

Day to day: `condortools sync`, then `condortools submit <file>`, then later `condortools fetch`.

- `sync` sends only code and the image. Inputs such as initial states need `condortools sync --also <paths>`: paths inside the project, kept as they are.
- `fetch` pulls `condor_data/` and `condorlogs/` back.
- `status` lists this project's queued jobs: state, host, number of starts, hold reason.
- `usage [cluster]` lists finished jobs: `job.sh`'s peak memory (read from the fetched stderr) against Condor's sampled value and the request, CPUs used against requested, and wall time.
- Everything else goes through ssh: `ssh octopus condor_rm|condor_release <cluster>`, `ssh octopus condor_tail <job>` for live output, `ssh octopus condor_q -better-analyze <job>` for why a job is idle. Each project folder belongs to one local project (`.origin`, written by the first `sync`); a second project with the same directory name is refused.
- **When a batch is done, run `condortools clean`.** It refuses while any job from the project's folder is still queued, held ones included. Otherwise it fetches, then deletes the results and the `--also` inputs (recorded by `sync` in `.also`), so data never piles up on octopus. Code and image stay for the next batch. `condortools clean --all` deletes the whole project folder instead; the next `sync` re-uploads everything (about 20 s).

Changed the Manifest? Run `condortools build`, then `condortools prune`, which deletes the old local images; the next `sync` removes them on octopus too.

## Sizing requests

Measure; never guess.

- **Memory:** `condortools fetch`, then `condortools usage <cluster>`. Size from `PeakMB(job.sh)`, the true peak. Condor's sampled `MemoryUsage` misses short peaks: 98–391 MB against 1.2–1.3 GB measured on the DipolarGas test. Set `request_memory` to about 1.5× the peak of a real-size run, at least 2 G. The test script is too small to size from.
- **CPUs:** time a fixed number of iterations at 1, 2 and 4 BLAS threads (`BLAS.set_num_threads`). Request more than one CPU only if it pays.
  - DipolarGas at D = 32: 0.32, 0.32 and 0.34 s per iteration at 1, 2 and 4 threads.
  - `CpusUsage` well below `request_cpus` means the request is wasted.
  - Smaller requests match more slots and count less against your user priority.
- Recheck when the bond dimension or model changes, and record the numbers in the project.

## Rules

- **Build alone.** It takes about 3 min and peaks at about 11 GB, with one CPU target (haswell, which runs on every node and the laptop). PackageCompiler's multi-target default was OOM-killed at 16.4 GB.
- **No `--workload`.** Baking a precompile workload into the image made a run 40% slower under Julia 1.12: GC 44% vs 17% of the time, 41 vs 7 full sweeps, the same allocation. Neither the heap-size hint nor more GC threads helped. Without it, first calls compile on the node, about 1 min per job.
- **Rebuild** when the Manifest changes (`condortools name` differs from the image) or when the nodes' Julia changes (re-run the test).
- **octopus `/home` is a shared disk**: 35 users, and your home is world-readable. A project there should be about 100 MB: sources plus the compressed image (83 MB for DipolarGas). Outputs only as named in `transfer_output_files`.
- **Compressed image:** zstd -19 shrinks it 6.5×. Each job's input transfer takes about 2 s; unpacking takes 2–40 s depending on the node's disk.

Measured 2026-10-28 (DipolarGas, Julia 1.12.7 6d172b025e4): nodes peps (skylake-avx512), erquaf (skylake-avx512) and tensorval (AMD Zen 5) all pass the full flow (`build`, `sync`, `submit`, `fetch`, `clean`). The test script ran 78–118 s, peaking at 1.2–1.3 GB; a real D = 32 run peaks at 1.07 GB.
