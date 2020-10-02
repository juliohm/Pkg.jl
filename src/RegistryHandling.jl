module RegistryHandling

using Base: UUID, SHA1, RefValue
using TOML
using Pkg.Versions: VersionSpec, VersionRange

const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")

struct VersionInfo
    git_tree_sha1::Base.SHA1
    # TODO: Collapse the dictionaries below into a single dictionary
    #compat::Dict{UUID, VersionSpec}
    compat::Dict{String, VersionSpec}
    deps::Dict{String, UUID}
    yanked::Bool
end

mutable struct Pkg
    path::String
    name::String
    uuid::UUID # could maybe remove this since it is a key in `RegistryInfo`
    repo::Union{String, Nothing}
    subdir::Union{String, Nothing}
    # Lazily constructed in `update!`
    version_info::Union{Dict{VersionNumber, VersionInfo}, Nothing}
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
        pkgpath = info["path"]::String
        name = info["name"]::String
        pkg = Pkg(pkgpath, name, uuid, nothing, nothing, nothing)
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

#=
function update_all!(r::Registry)
    isassigned(r.info) || initialize_registry!(r)
    foreach(u->update!(r, u), keys(r.info[].pkgs))
end
=#

function uncompress(::Type{T}, path::String, vsorted::AbstractVector{VersionNumber}, cache::Dict{String, T}, p::TOML.Parser) where {T}
    @assert issorted(vsorted)
    uncompressed = Dict{VersionNumber, Dict{String, T}}()
    isfile(path) || return uncompressed
    compressed = TOML.parsefile(p, path)
    if T == VersionSpec
        # The Compat.toml file might have vector values
        compressed = convert(Dict{String, Dict{String, Union{String, Vector{String}}}}, compressed)
    else
        # But the Deps.toml only have strings as values
        compressed = convert(Dict{String, Dict{String, String}}, compressed)
    end
    # Many of the entries are repeated so we keep a cache so there is no need to re-create
    # a bunch of identical objects
    for (vers, data) in compressed
        vs = VersionRange(vers)
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
            uv = get!(() -> Dict{String, T}(), uncompressed, v)
            for (key, value) in data
                if haskey(uv, key)
                    error("Overlapping ranges for $(key) in $(repr(path)) for version $v.")
                else
                    Tvalue = if value isa String
                        Tvalue = get!(()->T(value), cache, value)
                    else
                        Tvalue = T(value)
                    end
                    uv[key] = Tvalue
                end
            end
        end
    end
    return uncompressed
end

function update!(r::Registry, u::UUID)
    initialize_registry!(r)
    rpath = r.path
    r = r.info::RegistryInfo
    pkg = r.pkgs[u]
    # Already uncompressed the info for this package, return early
    pkg.version_info === nothing || return r
    path = joinpath(rpath, pkg.path)

    path_package = joinpath(path, "Package.toml")
    d_p = TOML.parsefile(r.p, path_package)
    name = d_p["name"]
    name != pkg.name && error("inconsistend name in Registry.toml and Package.toml for pkg at $(path)")
    pkg.repo = get(d_p, "repo", nothing)::Union{Nothing, String}
    pkg.subdir = get(d_p, "subdir", nothing)::Union{Nothing, String}

    # Read the versions from Versions.toml
    path_vers = joinpath(path, "Versions.toml")
    d_v = isfile(path_vers) ? TOML.parsefile(r.p, path_vers) : Dict{String, Any}()
    d_v = Dict{VersionNumber, Tuple{SHA1, Bool}}(VersionNumber(k) =>
        (SHA1(v["git-tree-sha1"]::String), get(v, "yanked", false)::Bool) for (k, v) in d_v)

    versions_sorted = sort!(VersionNumber[x for x in keys(d_v)])

    # Uncompress and store
    deps_data   = uncompress(UUID,        joinpath(path, "Deps.toml"),   versions_sorted, r.uuid_cache,        r.p)
    compat_data = uncompress(VersionSpec, joinpath(path, "Compat.toml"), versions_sorted, r.versionspec_cache, r.p)
    version_data = Dict{VersionNumber, VersionInfo}()
    for (v, (hash, yanked)) in d_v
        # TODO: Use when the collapsing of the two fields in VersionInfo is done
        #=
        d = Dict{UUID, VersionSpec}()
        deps_data_v = get(deps_data, v,  nothing)
        compat_data_v = get(compat_data, v, nothing)
        compat_data_v === nothing && continue
        for (name, compat) in compat_data_v
            is_julia = name == "julia"
            deps_data_v === nothing && @assert is_julia
            uuid = is_julia ? JULIA_UUID : deps_data_v[name]
            d[uuid] = compat
        end
        =#
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
    haskey(r.info.pkgs, uuid)
end

function Base.getindex(r::Registry, uuid::UUID)
    update!(r, uuid)
    r.info.pkgs[uuid]
end

function Base.get(r::Registry, uuid::UUID, default)
    update!(r, uuid)
    get(r.info.pkgs, uuid, default)
end


end
