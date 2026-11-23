module LibUtils

using stc_jll

const REPO_URL::String = "https://github.com/ShaderTranspiler/stc"

# used for init-time lib validation
const _LIB_FN_SYMS = Symbol[]

const _lib_fn_prefix::Symbol = :stc_

function _decl_fn(fn_name::Symbol, prepend_prefix::Bool=true)
    lib_fn::Symbol = prepend_prefix ? Symbol(_lib_fn_prefix, fn_name) : fn_name

    push!(_LIB_FN_SYMS, lib_fn)

    return lib_fn
end

# Typedefs

export STC_Status, STC_DumpVerbosity, STC_ResultHandle, STC_ConfigHandle

const STC_Status        = UInt8
const STC_DumpVerbosity = UInt8

const STC_ResultHandle = Ptr{Cvoid}
const STC_ConfigHandle = Ptr{Cvoid}

const _TYPEDEF_DEFAULT_VALUE = Dict(
    STC_Status => zero(UInt8),
    STC_DumpVerbosity => zero(UInt8),
    STC_ResultHandle => Ptr{Nothing}(0),
    STC_ConfigHandle => Ptr{Nothing}(0),
)

# List of constants to load during __init__

const LIB_CONSTANTS = Tuple{Symbol, DataType}[
    (:STC_SUCCESS,        STC_Status),
    (:STC_FAILED,         STC_Status),
    (:STC_INTERNAL_ERROR, STC_Status),
    
    (:STC_DUMP_VERBOSITY_NONE,    STC_DumpVerbosity),
    (:STC_DUMP_VERBOSITY_PARTIAL, STC_DumpVerbosity),
    (:STC_DUMP_VERBOSITY_VERBOSE, STC_DumpVerbosity),

    (:STC_NULL_RESULT, STC_ResultHandle),
    (:STC_NULL_CONFIG, STC_ConfigHandle),
]

export STC_STATUS_FIRST, STC_STATUS_LAST
export STC_DUMP_VERBOSITY_FIRST, STC_DUMP_VERBOSITY_LAST

# TODO: these should be exported by the C library for real 0.11
const STC_STATUS_FIRST::Ref{STC_Status} = Ref{STC_DumpVerbosity}(0x0)
const STC_STATUS_LAST::Ref{STC_Status} = Ref{STC_DumpVerbosity}(0x0)
const STC_DUMP_VERBOSITY_FIRST::Ref{STC_DumpVerbosity} = Ref{STC_DumpVerbosity}(0x0)
const STC_DUMP_VERBOSITY_LAST::Ref{STC_DumpVerbosity} = Ref{STC_DumpVerbosity}(0x0)

macro _gen_lib_consts()
    exprs = sizehint!(Expr[], 2 * length(LIB_CONSTANTS))
    for (name, type) in LIB_CONSTANTS
        default = _TYPEDEF_DEFAULT_VALUE[type]
        push!(exprs, :(export $name))
        push!(exprs, :(const global $name::Ref{$type} = Ref{$type}($default)))
    end

    return esc(Expr(:block, exprs...))
end

@_gen_lib_consts()

export @load_lib_constants

# meant to be called during __init__
macro load_lib_constants(lib)
    exprs = sizehint!(Expr[], length(LIB_CONSTANTS))
    for (name, type) in LIB_CONSTANTS
        push!(exprs, :($name[] = $unsafe_load($cglobal(($(QuoteNode(name)), $(esc(lib))), $type))))
    end

    push!(exprs, :($STC_STATUS_FIRST[] = $STC_SUCCESS[]))
    push!(exprs, :($STC_STATUS_LAST[] = $STC_INTERNAL_ERROR[]))
    push!(exprs, :($STC_DUMP_VERBOSITY_FIRST[] = $STC_DUMP_VERBOSITY_NONE[]))
    push!(exprs, :($STC_DUMP_VERBOSITY_LAST[] = $STC_DUMP_VERBOSITY_VERBOSE[]))

    return Expr(:block, exprs...)
end

# Version API
export LIBSTC_FN_ABI_VERSION, LIBSTC_FN_VERSION_MAJOR, LIBSTC_FN_VERSION_MINOR, LIBSTC_FN_VERSION_PATCH, LIBSTC_FN_VERSION_STRING

const LIBSTC_FN_ABI_VERSION::Symbol = _decl_fn(:abi_version)
const LIBSTC_FN_VERSION_MAJOR::Symbol = _decl_fn(:version_major)
const LIBSTC_FN_VERSION_MINOR::Symbol = _decl_fn(:version_minor)
const LIBSTC_FN_VERSION_PATCH::Symbol = _decl_fn(:version_patch)
const LIBSTC_FN_VERSION_STRING::Symbol = _decl_fn(:version_string)

# Transpile API
export LIBSTC_FN_TRANSPILE, LIBSTC_FN_TRANSPILE_CODE, LIBSTC_FN_GET_RESULT, LIBSTC_FN_FREE_RESULT

const LIBSTC_FN_TRANSPILE::Symbol = _decl_fn(:transpile)
const LIBSTC_FN_TRANSPILE_CODE::Symbol = _decl_fn(:transpile_code)
const LIBSTC_FN_GET_RESULT::Symbol = _decl_fn(:get_result)
const LIBSTC_FN_FREE_RESULT::Symbol = _decl_fn(:free_result)

# Config API
export LIBSTC_FN_CREATE_CFG, LIBSTC_FN_FREE_CFG, LIBSTC_FN_RESET_INITIAL_SIZES, CFG_OPTIONS

const LIBSTC_FN_CREATE_CFG::Symbol = _decl_fn(:create_cfg)
const LIBSTC_FN_FREE_CFG::Symbol = _decl_fn(:free_cfg)

const LIBSTC_FN_RESET_INITIAL_SIZES::Symbol = _decl_fn(:reset_initial_sizes)

const CFG_OPTIONS = [
    (:code_gen_indent, UInt16),
    (:use_tabs,        Bool),
    
    (:warn_on_jl_sema_query,     Bool),
    (:warn_strict_conformance,   Bool),
    (:dump_scopes,               Bool),
    (:print_convert_fail_reason, Bool),

    (:error_dump_verbosity, STC_DumpVerbosity),

    (:forward_fns,       Bool),
    (:coerce_to_f32,     Bool),
    (:coerce_to_i32,     Bool),
    (:coerce_non_finite, Bool),
    (:capture_uniforms,  Bool),
    
    (:target_version, String),
    (:local_size_x,   UInt32),
    (:local_size_y,   UInt32),
    (:local_size_z,   UInt32),
    (:local_size,     Tuple{UInt32,UInt32,UInt32}),

    (:gl_utils_path, String),
    (:gl_utils_mod,  Module),
    (:fallback_file_path, String),

    (:track_timing,   Bool),
    (:track_memory,   Bool),
    (:dump_parsed,    Bool),
    (:dump_sema,      Bool),
    (:dump_lowered,   Bool),
    (:dump_indent,    UInt16),
    (:track_bindings, Bool),

    (:initial_julia_node_pool_size,  UInt32),
    (:initial_sir_node_pool_size,    UInt32),
    (:initial_symbol_pool_size,      UInt32),
    (:initial_source_info_pool_size, UInt32),
    (:initial_type_pool_size,        UInt16),
    (:initial_qualifier_pool_size,   UInt16),
    (:initial_pool_sizes,            Tuple{UInt32, UInt32, UInt32,
                                           UInt32, UInt16, UInt16}),
]

macro _gen_cfg_consts()
    exprs = sizehint!(Expr[], length(CFG_OPTIONS) * 2)

    for (opt, _) in CFG_OPTIONS
        lib_fn::Symbol = Symbol("set_", opt)
        const_name::Symbol = Symbol("LIBSTC_FN_", uppercase(string(lib_fn)))

        push!(exprs, :(export $const_name))
        push!(exprs, :(const $const_name::Symbol = $(_decl_fn)($(QuoteNode(lib_fn)))))
    end

    return esc(Expr(:block, exprs...))
end

@_gen_cfg_consts

end
