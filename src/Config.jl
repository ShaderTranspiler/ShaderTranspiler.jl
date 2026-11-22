module Config

export ConfigHandle
export unsafe_free_config_handle!
export set_error_dump_verbosity!, reset_initial_sizes!

public unsafe_create_config_handle

using stc_jll
using ..ShaderTranspiler: CFG_OPTIONS
using ..ShaderTranspiler.LibUtils

"""
RAII-esque type that wraps a low-level config handle
"""
mutable struct ConfigHandle
    value::STC_ConfigHandle

    function ConfigHandle()
        value = unsafe_create_config_handle()
        value == STC_NULL_CONFIG[] && error("Couldn't obtain a config handle through libstc")

        handle = new(value)
        finalizer(unsafe_free_config_handle!, handle)

        return handle
    end

    ConfigHandle(value::STC_ConfigHandle) = new(value)
end

"""
    unsafe_create_config_handle()::STC_ConfigHandle

Low-level endpoint for acquiring a new configuration handle from the stc library. External use is discouraged in favor of using `ConfigHandle`-s.

Throws `STCLibError` on failure, which indicates the library returned a null pointer.
"""
function unsafe_create_config_handle()::STC_ConfigHandle
    value = ccall((LIBSTC_FN_CREATE_CFG, libstc), STC_ConfigHandle, ())
    value == STC_NULL_CONFIG[] && throw(STCLibError("Couldn't create configuration handle.", LIBSTC_FN_CREATE_CFG))
    return value
end

"""
    unsafe_free_config_handle!(handle::Union{ConfigHandle, STC_ConfigHandle})

Frees a configuration handle and makes it point to `STC_NULL_CONFIG`. If `handle` already points to `STC_NULL_CONFIG`, this is a no-op.

NOTE: handles obrained through the argumentless `ConfigHandle` constructor DO NOT NEED to be (but optionally CAN be) freed manually, this is automatically handled by a finalizer.
"""
function unsafe_free_config_handle!(handle::STC_ConfigHandle)::Nothing
    handle == STC_NULL_CONFIG[] && return
    ccall((LIBSTC_FN_FREE_CFG, libstc), Cvoid, (STC_ConfigHandle,), handle)
    return nothing
end

function unsafe_free_config_handle!(handle::ConfigHandle)::Nothing
    unsafe_free_config_handle!(handle.value)
    handle.value = STC_NULL_CONFIG[]
    return nothing    
end

"""
    set_error_dump_verbosity!(handle::ConfigHandle, value::STC_DumpVerbosity)

Wrapper for modifyig the error_dump_verbosity transpiler option from Julia.
`value` must be a valid STC_DumpVerbosity value.

Throws `DomainError` if value is not one of the above options.
"""
function set_error_dump_verbosity!(handle::STC_ConfigHandle, value::STC_DumpVerbosity)
    if !(LibUtils.STC_DUMP_VERBOSITY_FIRST[] <= value <= LibUtils.STC_DUMP_VERBOSITY_LAST[])
        throw(DomainError(value, "Invalid STC_DumpVerbosity value: $value\nValue must be in range [$(LibUtils.STC_DUMP_VERBOSITY_FIRST[]), $(LibUtils.STC_DUMP_VERBOSITY_LAST[])]"))
    end

    if handle != STC_NULL_CONFIG[]
        ccall((LIBSTC_FN_SET_ERROR_DUMP_VERBOSITY, libstc), Cvoid, (STC_ConfigHandle, UInt8), handle, value)
    end
end
set_error_dump_verbosity!(handle::ConfigHandle, value::STC_DumpVerbosity) = set_error_dump_verbosity!(handle.value, value)

"""
    reset_initial_sizes!(handle::ConfigHandle)

Resets initial pool arena sizes to their default values.
"""
function reset_initial_sizes!(handle::STC_ConfigHandle)
    handle == STC_NULL_CONFIG[] && return
    ccall((LIBSTC_FN_RESET_INITIAL_SIZES, libstc), Cvoid, (Ptr{Cvoid},), handle)
end
reset_initial_sizes!(handle::ConfigHandle) = reset_initial_sizes!(handle.value)

macro _gen_cfg_setters()
    fn_defs::Vector{Expr} = Expr[]
    sizehint!(fn_defs, length(CFG_OPTIONS) - 1)

    for (opt, ValTy) in CFG_OPTIONS
        opt == :error_dump_verbosity && continue

        fn_name = Symbol("set_", opt, "!")
        lib_fn_const = Symbol("LIBSTC_FN_SET_", uppercase(string(opt)))

        doc_str = """
            $fn_name(handle::ConfigHandle, value::$ValTy)
            $fn_name(handle::STC_ConfigHandle, value::$ValTy)
        
        Wrapper for modifying the `$opt` transpiler option from Julia.
        """

        ArgTy = ValTy == String ? Cstring : ValTy

        if ArgTy <: Tuple
            @assert length(ArgTy.parameters) != 0
        end

        base_fn_def =
            if ArgTy <: Tuple
                arg_tys::Vector{DataType} = [T for T in ValTy.parameters]

                ccall_sig::Expr = :(Ptr{Cvoid}, $(Symbol.(arg_tys)...))
                ccall_args::Vector{Expr} = [:(value[$i]) for i in 1:length(arg_tys)]

                :(function $fn_name(handle::$STC_ConfigHandle, value::$ValTy)
                    handle == $STC_NULL_CONFIG[] && return
                    ccall(($lib_fn_const, libstc), Cvoid, $ccall_sig, handle, $(ccall_args...))
                end)
            else
                :(function $fn_name(handle::$STC_ConfigHandle, value::$ValTy)
                    handle == $STC_NULL_CONFIG[] && return
                    ccall(($lib_fn_const, libstc), Cvoid, ($STC_ConfigHandle, $ArgTy), handle, value)
                end)
            end

        fn_def = quote
            export $fn_name

            @doc $doc_str
            $base_fn_def

            function $fn_name(handle::ConfigHandle, value::$ValTy)
                $(fn_name)(handle.value, value)
            end
        end

        push!(fn_defs, fn_def)
    end

    return esc(Expr(:block, fn_defs...))
end

@_gen_cfg_setters

macro _gen_main_setter()
    fn::Expr = :(
        function set_config_opts!(handle::$ConfigHandle;)
            handle.value == $STC_NULL_CONFIG[] && return
        end
    )

    fn_kwargs::Expr = fn.args[1].args[2]
    fn_body::Expr = fn.args[2]

    @assert Meta.isexpr(fn_kwargs, :parameters, 0)

    sizehint!(fn_kwargs.args, length(CFG_OPTIONS))
    sizehint!(fn_body.args, length(CFG_OPTIONS) + 3) # 2 generated line number nodes + null check

    for (opt, ValTy) in CFG_OPTIONS
        setter_name::Symbol = Symbol("set_", opt, "!")

        kwarg::Expr = Expr(:kw, :($(opt)::Union{$ValTy,Nothing}), nothing)
        push!(fn_kwargs.args, kwarg)

        push!(fn_body.args, :(
            if $opt !== nothing
                $setter_name(handle, $opt)
            end
        ))

    end

    return esc(fn)
end

function _gen_main_setter_docs()
    doc_lines::Vector{String} = String[
        "set_config_opts!(handle::ConfigHandle; kwargs...)",
        "",
        "Sets the provided options for the configuration pointed to by `handle`. Acts as a no-op if `handle` points to `STC_NULL_CONFIG`.
        Otherwise identical to calling the ShaderTranspiler.Config.set_<option name>! functions for every argument individually.",
        "",
        "kwarg options are:"
    ]
    sizehint!(doc_lines, length(doc_lines) + length(CFG_OPTIONS))

    for (opt, ValTy) in CFG_OPTIONS
        push!(doc_lines, "- $(replace(string(opt), '_' => "\\_"))::$ValTy")
    end

    return join(doc_lines, '\n')
end

export set_config_opts!

@doc _gen_main_setter_docs()
@_gen_main_setter

end
