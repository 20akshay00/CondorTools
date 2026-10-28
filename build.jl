# Build a system image of every dependency of a Julia project (not the project itself), for
# condor jobs: no registry, no downloads, no precompilation of dependencies on the node.
# See README.md before using it, in particular the test job.
#
# Run (alone: peaks at ~11 GB):
#   julia --project=<this folder> <this folder>/build.jl <project dir> [--exclude A,B] [--workload file.jl]
#
# Writes <project>/remote/sysimage/deps-<h>.so, h the first 8 hex digits of the SHA-1 of the
# project's Manifest.toml (a different Manifest needs a new image), and next to it
# deps-<h>.so.zst (zstd -19 --long=27, ~6.5x smaller; what jobs ship; the .so itself is then
# deleted: `zstd -d --long=27` restores it) and
# deps-<h>_depot/artifacts: the binary libraries of the JLL packages, which are not in the
# image but looked up in a depot when it loads (JLLs shipped with Julia are not needed).
# Also writes remote/sysimage/image.sub, `IMAGE = remote/sysimage/deps-<h>`, which submit
# files include (`include : remote/sysimage/image.sub`), so a new image needs no edits there.

using PackageCompiler, TOML, SHA, Pkg.Artifacts

function parse_args(args)
    project = abspath(args[1])
    exclude, workload = String[], nothing
    i = 2
    while i <= length(args)
        args[i] == "--exclude" ? (exclude = split(args[i+1], ",")) :
        args[i] == "--workload" ? (workload = abspath(args[i+1])) :
        error("unknown argument $(args[i])")
        i += 2
    end
    return project, exclude, workload
end

project, exclude, workload = parse_args(ARGS)
h = bytes2hex(open(sha1, joinpath(project, "Manifest.toml")))[1:8]
out = joinpath(project, "remote", "sysimage", "deps-$h.so")
mkpath(dirname(out))
deps = setdiff(sort(collect(keys(TOML.parsefile(joinpath(project, "Project.toml"))["deps"]))), exclude)
println("packages: ", join(deps, ", "), "\nimage: ", out)

# One target: haswell (AVX2) runs on every condor node (x86_64-v4) and on the laptop. The
# multi-target default compiles every function three times and peaked above 16 GB.
# A workload bakes traced specialisations in: faster first calls, but under Julia 1.12 it
# tripled the GC's full sweeps at run time (README).
create_sysimage(Symbol.(deps); project, sysimage_path=out, cpu_target="haswell",
    (isnothing(workload) ? (;) : (; precompile_execution_file=workload))...)

pushfirst!(LOAD_PATH, project)                    # to locate the project's JLLs
depot = joinpath(splitext(out)[1] * "_depot", "artifacts")
mkpath(depot)
for (name, entries) in TOML.parsefile(joinpath(project, "Manifest.toml"))["deps"]
    e = only(entries)
    (endswith(name, "_jll") && haskey(e, "git-tree-sha1")) || continue
    toml = joinpath(dirname(dirname(Base.locate_package(Base.PkgId(Base.UUID(e["uuid"]), name)))), "Artifacts.toml")
    for a in keys(TOML.parsefile(toml))
        meta = artifact_meta(a, toml)
        isnothing(meta) && continue
        sha = meta["git-tree-sha1"]
        cp(artifact_path(Base.SHA1(sha)), joinpath(depot, sha); force=true)
        println("artifact: ", name, " ", sha)
    end
end

run(`zstd -q -f -19 -T4 --long=27 --rm $out -o $out.zst`)
println("compressed: ", out, ".zst (the .so removed)")
write(joinpath(dirname(out), "image.sub"), "IMAGE = remote/sysimage/deps-$h\n")
