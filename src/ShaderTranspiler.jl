module ShaderTranspiler

using Libdl
using stc_jll

include("STCLibError.jl")

include("LibUtils.jl")
using .LibUtils
export STC_Status, STC_DumpVerbosity, STC_ConfigHandle, STC_ResultHandle
export STC_SUCCESS, STC_FAILED, STC_INTERNAL_ERROR
public STC_STATUS_FIRST, STC_STATUS_LAST
export STC_DUMP_VERBOSITY_NONE, STC_DUMP_VERBOSITY_PARTIAL, STC_DUMP_VERBOSITY_VERBOSE
public STC_DUMP_VERBOSITY_FIRST, STC_DUMP_VERBOSITY_LAST
export STC_NULL_RESULT, STC_NULL_CONFIG

include("Config.jl")
using .Config
public Config
export ConfigHandle, unsafe_free_config_handle!, set_config_opts!

import GLUtils

include("transpile.jl")
include("qual_macros.jl")

public abi_version, check_abi
export stc_version, stc_version_string

abi_version()::UInt8 = ccall((LIBSTC_FN_ABI_VERSION, libstc), UInt8, ())
stc_version()::VersionNumber = VersionNumber(
    ccall((LIBSTC_FN_VERSION_MAJOR, libstc), UInt8, ()),
    ccall((LIBSTC_FN_VERSION_MINOR, libstc), UInt8, ()),
    ccall((LIBSTC_FN_VERSION_PATCH, libstc), UInt8, ())
)

# this is statically allocated memory, so we don't free
stc_version_string(include_commit_hash::Bool = false)::String =
    unsafe_string(ccall((LIBSTC_FN_VERSION_STRING, libstc), Cstring, (Bool,), include_commit_hash))

function check_abi(print_success::Bool=true)::Nothing
    lib_abi_ver = abi_version()
    pkg_ver = pkgversion(ShaderTranspiler)

    if pkg_ver.major < lib_abi_ver
        error("ABI version of libstc loaded by stc_jll ($lib_abi_ver) is incompatible with the current Pkg major version ($pkg_ver)")
    end

    if pkg_ver.major == lib_abi_ver == 0 && pkg_ver.minor != stc_version().minor
        @warn "ABI version of ShaderTranspiler.jl and stc_jll.jl's libstc matches (0), but minor version differs. Make sure the two instances are actually ABI compatible!"
    end

    print_success && println("libstc ABI version and Pkg major version are compatible")

    return nothing
end

function __init__()
    pkg_ver = pkgversion(ShaderTranspiler)

    if !hasproperty(stc_jll, :libstc)
        url_ver_rc_str = pkg_ver !== nothing && !isempty(pkg_ver.prerelease) ? "-rc.$(pkg_ver.prerelease[2])" : ""
        url_ver_str = pkg_ver !== nothing ? "v$(pkg_ver.major).$(pkg_ver.minor).$(pkg_ver.patch)$url_ver_rc_str" : ""

        error("Couldn't find libstc in stc_jll!\n",
              "This most likely indicates that your current Julia version is not supported by stc and thus not resolvable via stc_jll.\n",
              "Check the README.md and julia_targets.toml files at your target version's tag in $(LibUtils.REPO_URL) to find Julia support information.\n",
              "Note that trying to import the package again will succeed, but the transpiler will be unusable.",
              pkg_ver !== nothing ? "\nYour target version: $(pkg_ver)" : "",
              pkg_ver !== nothing ? "\nYour version's tree: $(LibUtils.REPO_URL)/tree/$url_ver_str" : "")
    end

    handle = Libdl.dlopen(libstc; throw_error=false)
    if handle === nothing
        error("Couldn't open libstc from the path provided by stc_jll, this is an unrecoverable internal error.", false)
    end

    _check_sym_exists(handle, LIBSTC_FN_ABI_VERSION)

    if pkg_ver === nothing
        @warn "Couldn't retrieve ShaderTranspiler's Pkg version at initialization time, ABI compatibility check will be skipped. To perform this check manually, call ShaderTranspiler.check_abi() after initialization."
    else
        check_abi(false)
    end

    for lib_fn in LibUtils._LIB_FN_SYMS
        _check_sym_exists(handle, lib_fn)
    end

    for (lib_const, _) in LibUtils.LIB_CONSTANTS
        _check_sym_exists(handle, lib_const)
    end

    Libdl.dlclose(handle)

    @load_lib_constants libstc
end

include("CLI.jl")

function _check_sym_exists(handle::Ptr{Nothing}, sym::Symbol)
    if Libdl.dlsym(handle, sym; throw_error=false) === nothing
        error("Couldn't find symbol '$sym' in the stc library acquired from stc_jll. ",
            "This is an unrecoverable internal error in the wrapping logic itself. ",
            "It most likely indicates that an FFI breaking C ABI change in the library was not appropriately updated in ShaderTranspiler.jl")
    end
end

include("precompile.jl")

end
