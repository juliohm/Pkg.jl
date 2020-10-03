module RegistryHandling

using Base: UUID, SHA1, RefValue
using TOML
#using Pkg.Versions: VersionSpec, VersionRange
using Pkg.Types: VersionSpec, VersionRange

const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")

# Info about each version of a package
mutable struct VersionInfo
    git_tree_sha1::Base.SHA1
    yanked::Bool

    # This is the uncompressed info and is lazily computed because it is kinda expensive
    # TODO: Collapse the two dictionaries below into a single dictionary,
    # we should only need to know the `Dict{UUID, VersionSpec}` mapping
    # (therebe getting rid of the package names).
    uncompressed_compat::Union{Dict{String, VersionSpec}, Nothing}
    uncompressed_deps::Union{Dict{String, UUID}, Nothing}
end
VersionInfo(git_tree_sha1::Base.SHA1, yanked::Bool) = VersionInfo(git_tree_sha1, yanked, nothing, nothing)

# Lazily initialized
mutable struct PkgInfo
    # Package.toml:
    repo::Union{String, Nothing}
    subdir::Union{String, Nothing}

    # Versions.toml:
    version_info::Dict{VersionNumber, VersionInfo}

    # Compat.toml
    compat::Dict{VersionRange, Dict{String, VersionSpec}}

    # Deps.toml
    deps::Dict{VersionRange, Dict{String, UUID}}

    uncompressed_initialized::Bool
end

mutable struct Pkg
    # Registry.toml:
    path::String
    name::String
    uuid::UUID

    # Version.toml / (Compat.toml / Deps.toml):
    info::Union{PkgInfo, Nothing}
end

# Call this before accessing uncompressed data
function initialize_uncompressed!(pkg::Pkg)
    @assert pkg.info !== nothing
    pkg = pkg.info::PkgInfo
    pkg.uncompressed_initialized && return pkg

    vsorted = sort!(collect(keys(pkg.version_info)))
    uncompressed_compat = uncompress(pkg.compat, vsorted)
    uncompressed_deps   = uncompress(pkg.deps,   vsorted)
    #=
    @show keys(uncompressed_compat)
    @show keys(uncompressed_deps)
    @show keys(pkg.version_info)
    =#
    #@assert keys(uncompressed_compat) == keys(uncompressed_deps) == keys(pkg.version_info)
    for v in vsorted
        vinfo = pkg.version_info[v]
        # TODO: Use when collapsing the two fields in VersionInfo is to be implemented
        #=
        d = Dict{UUID, VersionSpec}()
        uncompressed_deps_v = uncompressed_deps[v]
        for (name, compat) in uncompressed_compat[v]
            is_julia = name == "julia"
            uuid = get(uncompressed_deps_v, name, nothing)
            uuid === nothing && @assert is_julia
            uuid = is_julia ? JULIA_UUID : uuid
            d[uuid] = compat
        end
        =#
        vinfo.uncompressed_compat = get(Dict{String, VersionSpec}, uncompressed_compat, v)
        vinfo.uncompressed_deps = get(Dict{String, UUID}, uncompressed_deps, v)
    end
    pkg.uncompressed_initialized = true
    return pkg
end

function uncompress(compressed::Dict{VersionRange, Dict{String, T}}, vsorted::Vector{VersionNumber}) where {T}
    @assert issorted(vsorted)
    uncompressed = Dict{VersionNumber, Dict{String, T}}()
    # Many of the entries are repeated so we keep a cache so there is no need to re-create
    # a bunch of identical objects
    for (vs, data) in compressed
        first = length(vsorted) + 1
        # We find the first and last version that are in the range
        # and since the versions are sorted, all versions in between are sorted
        for i in eachindex(vsorted)
            v = vsorted[i]
            v in vs && (first = i; break)
        end
        last = 0
        for i in reverse(eachindex(vsorted))
            v = vsorted[i]
            v in vs && (last = i; break)
        end
        for i in first:last
            v = vsorted[i]
            uv = get!(Dict{String, T}, uncompressed, v)
            for (key, value) in data
                if haskey(uv, key)
                    # Change to an error?
                    error("Overlapping ranges for $(key) in $(repr(path)) for version $v.")
                else
                    uv[key] = value
                end
            end
        end
    end
    return uncompressed
end

struct RegistryInfo
    name::String
    uuid::UUID
    url::Union{String, Nothing}
    repo::Union{String, Nothing}
    description::Union{String, Nothing}
    pkgs::Dict{UUID, Pkg}
    # various caches
    p::TOML.Parser
    uuid_cache::Dict{String, UUID}
    versionspec_cache::Dict{String, VersionSpec}
    name_to_uuids::Dict{String, Vector{UUID}}
end

mutable struct Registry
    path::String
    # Lazyily constructed
    info::Union{RegistryInfo, Nothing}
end

Registry(path::AbstractString) = Registry(path, nothing)

function Base.show(io::IO, ::MIME"text/plain", r::Registry)
    if r.info === nothing
        println(io, "Registry: at $(repr(r.path)) [uninitialized]")
    else
        path = r.path
        r = r.info
        println(io, "Registry: $(repr(r.name)) at $(repr(path)):")
        println(io, "  uuid: ", r.uuid)
        println(io, "  repo: ", r.repo)
        println(io, "  subdir: ", r.repo)
        println(io, "  packages: ", length(r.pkgs))
    end
end

function initialize_registry!(r::Registry)
    r.info === nothing || return r
    p = TOML.Parser()
    d = TOML.parsefile(p, joinpath(r.path, "Registry.toml"))
    pkgs = Dict{UUID, Pkg}()
    for (uuid, info) in d["packages"]::Dict{String, Any}
        uuid = UUID(uuid::String)
        info::Dict{String, Any}
        name = info["name"]::String
        name === "julia" && continue
        pkgpath = info["path"]::String
        pkg = Pkg(pkgpath, name, uuid, nothing)
        pkgs[uuid] = pkg
    end
    r.info = RegistryInfo(
        d["name"]::String,
        UUID(d["uuid"]::String),
        get(d, "url", nothing)::Union{String, Nothing},
        get(d, "repo", nothing)::Union{String, Nothing},
        get(d, "description", nothing)::Union{String, Nothing},
        pkgs,
        p,
        Dict{String, UUID}(),
        Dict{String, VersionSpec}(),
        Dict{String, Vector{UUID}}(),
    )
    return r
end

function update_package!(r::Registry, u::UUID)
    initialize_registry!(r)
    rpath = r.path
    r = r.info::RegistryInfo
    pkg = r.pkgs[u]
    # Already uncompressed the info for this package, return early
    pkg.info === nothing || return r
    path = joinpath(rpath, pkg.path)

    path_package = joinpath(path, "Package.toml")
    d_p = TOML.parsefile(r.p, path_package)
    name = d_p["name"]::String
    name != pkg.name && error("inconsistend name in Registry.toml and Package.toml for pkg at $(path)")
    repo = get(d_p, "repo", nothing)::Union{Nothing, String}
    subdir = get(d_p, "subdir", nothing)::Union{Nothing, String}

    # Versions.toml
    path_vers = joinpath(path, "Versions.toml")
    d_v = isfile(path_vers) ? TOML.parsefile(r.p, path_vers) : Dict{String, Any}()
    version_info = Dict{VersionNumber, VersionInfo}(VersionNumber(k) =>
        VersionInfo(SHA1(v["git-tree-sha1"]::String), get(v, "yanked", false)::Bool) for (k, v) in d_v)

    # Compat.toml
    compat_file = joinpath(path, "Compat.toml")
    compat_data_toml = isfile(compat_file) ? TOML.parsefile(r.p, compat_file) : Dict{String, Any}()
    # The Compat.toml file might have string or vector values
    compat_data_toml = convert(Dict{String, Dict{String, Union{String, Vector{String}}}}, compat_data_toml)
    compat = Dict{VersionRange, Dict{String, VersionSpec}}()
    for (v, data) in compat_data_toml
        vr = VersionRange(v)
        d = Dict{String, VersionSpec}(dep => VersionSpec(vr_dep) for (dep, vr_dep) in data)
        compat[vr] = d
    end

    # Deps.toml
    deps_file = joinpath(path, "Deps.toml")
    deps_data_toml = isfile(deps_file) ? TOML.parsefile(r.p, deps_file) : Dict{String, Any}()
    # But the Deps.toml only have strings as values
    deps_data_toml = convert(Dict{String, Dict{String, String}}, deps_data_toml)
    deps = Dict{VersionRange, Dict{String, UUID}}()
    for (v, data) in deps_data_toml
        vr = VersionRange(v)
        d = Dict{String, UUID}(dep => UUID(uuid) for (dep, uuid) in data)
        deps[vr] = d
    end

    pkg.info = PkgInfo(repo, subdir, version_info, compat, deps, false)

    return pkg
end

function uncompress!(r::Registry, uuid::UUID)
    pkg = r[uuid]
    # Uncompress and store
    version_data = Dict{VersionNumber, VersionInfo}()
    for (v, (hash, yanked)) in d_v
        compat_data_v = get(Dict{String, VersionSpec}, compat_data, v)
        deps_data_v = get(Dict{String, UUID}, deps_data, v)
        version_data[v] = VersionInfo(hash, compat_data_v, deps_data_v, yanked)
    end
    pkg.version_info = version_data
    return

end


# API

function collect_reachable_registries(; depots=Base.DEPOT_PATH)
    # collect registries
    registries = Registry[]
    for d in depots
        isdir(d) || continue
        reg_dir = joinpath(d, "registries")
        isdir(reg_dir) || continue
        for name in readdir(reg_dir)
            file = joinpath(reg_dir, name, "Registry.toml")
            isfile(file) || continue
            push!(registries, Registry(joinpath(reg_dir, name)))
        end
    end
    return registries
end


function uuids_from_name(r::Registry, name::String)
    initialize_registry!(r)
    create_name_uuid_mapping!(r)
    return get(Vector{UUID}, r.info.name_to_uuids, name)
end

function create_name_uuid_mapping!(r::Registry)
    initialize_registry!(r)
    isempty(r.info.name_to_uuids) || return
    for (uuid, pkg) in r.info.pkgs
        uuids = get!(Vector{UUID}, r.info.name_to_uuids, pkg.name)
        push!(uuids, pkg.uuid)
    end
    return
end

function Base.haskey(r::Registry, uuid::UUID)
    initialize_registry!(r)
    return haskey(r.info.pkgs, uuid)
end

function Base.keys(r::Registry)
    initialize_registry!(r)
    return keys(r.info.pkgs)
end

function Base.getindex(r::Registry, uuid::UUID)
    update!(r, uuid)
    return r.info.pkgs[uuid]
end

function Base.get(r::Registry, uuid::UUID, default)
    update!(r, uuid)
    return get(r.info.pkgs, uuid, default)
end

# Some stuff useful for timing / debugging
function update_all!(r::Registry)
    r.info === nothing && initialize_registry!(r)
    foreach(u->update_package!(r, u), keys(r.info.pkgs))
end

function uncompress_all!(r::Registry)
    r.info === nothing && initialize_registry!(r)
    foreach(initialize_uncompressed!, values(r.info.pkgs))
end

end

#=
r = RegistryHandling.Registry(joinpath(homedir(), ".julia/registries/General"))
@time RegistryHandling.update_all!(r)
@time RegistryHandling.uncompress_all!(r)
r = RegistryHandling.Registry(joinpath(homedir(), ".julia/registries/General"))
@time RegistryHandling.update_all!(r)
@time RegistryHandling.uncompress_all!(r)

pkg = RegistryHandling.update_package!(r, Base.UUID("739be429-bea8-5141-9913-cc70e7f3736d"))

RegistryHandling.initialize_uncompressed!(pkg)
=#
