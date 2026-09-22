module ShaderTranspiler

using Libdl
using stc_jll

include("STCLibError.jl")

include("lib_utils.jl")
using .LibUtils

include("Config.jl")
using .Config

#! format: off
public Config
#! format: on
export ConfigHandle, free_config_handle!, set_config_opts!

include("transpile.jl")
include("qual_macros.jl")

#! format: off
public abi_version, check_abi
#! format: on

abi_version()::UInt8 = ccall((LIBSTC_ABI_VERSION, libstc), UInt8, ())

function check_abi(print_success::Bool=true)
    lib_abi_ver = abi_version()
    pkg_ver = pkgversion(ShaderTranspiler)

    if pkg_ver.major < lib_abi_ver
        error("ABI version of libstc loaded by stc_jll ($lib_abi_ver) is incompatible with the current Pkg major version ($pkg_abi_ver)")
    end

    print_success && println("libstc ABI version and Pkg major version are compatible")
end

function __init__()
    function check_fn_exists(fn::Symbol)
        sym = Libdl.dlsym(handle, fn; throw_error=false)

        if sym === nothing
            error("Couldn't find function named $fn in the stc library acquired from the jll.",
                "This is an unrecoverable internal error in the wrapping logic itself.",
                "It most likely indicates that an FFI breaking C ABI change in the library was not appropriately updated in ShaderTranspiler.jl")
        end
    end

    pkg_ver = pkgversion(ShaderTranspiler)
    
    if !hasproperty(stc_jll, :libstc)
        url_ver_str = pkg_ver !== nothing ? "v$(pkg_ver.major).$(pkg_ver.minor).$(pkg_ver.patch)-rc.$(pkg_ver.prerelease[2])" : ""

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

    check_fn_exists(LIBSTC_ABI_VERSION)

    if pkg_ver === nothing
        @warn "Couldn't retrieve ShaderTranspiler's Pkg version at initialization time, ABI compatibility check will be skipped. To perform this check manually, call ShaderTranspiler.check_abi() after initialization."
    else
        check_abi(false)
    end

    for lib_fn in LibUtils._LIB_FN_SYMS
        check_fn_exists(lib_fn)
    end

    Libdl.dlclose(handle)
end

include("CLI.jl")

end
