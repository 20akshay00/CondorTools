#!/bin/bash
# Condor job wrapper: job.sh <image .so> <julia arguments...>
# Unpacks <image>.so.zst if only that was shipped, then runs
#   julia -J <image> --project=. <julia arguments...>
# on the job's empty depot with no Pkg step (the image holds every dependency; its JLL
# libraries are in <image>_depot). Logs the node's Julia build and CPU, and the run's peak
# memory (/usr/bin/time -v: "Maximum resident set size"), to stderr. Deletes the unpacked
# image afterwards, so that it is never transferred back.
img=$1; shift
export JULIA_PKG_OFFLINE=true JULIA_DEPOT_PATH="$HOME/.julia:$PWD/${img%.so}_depot"
[[ -f $img ]] || zstd -q -d --long=27 "$img.zst" || exit 1
/usr/local/bin/julia --startup-file=no -e 'println(stderr, "julia ", VERSION, " ", Base.GIT_VERSION_INFO.commit_short, " on ", Sys.CPU_NAME, " ", gethostname())'
/usr/bin/time -v /usr/local/bin/julia --startup-file=no -J "$img" --project=. "$@"
status=$?
[[ -f $img.zst ]] && rm -f "$img"
exit $status
