using PrecompileTools: @setup_workload, @compile_workload

# throwaway value for each config type
_pc_value(::Type{Bool}) = false
_pc_value(::Type{T}) where {T<:Integer} = one(T)
_pc_value(::Type{String}) = ""
_pc_value(::Type{T}) where {T<:Tuple} = map(_pc_value, fieldtypes(T))

if hasproperty(stc_jll, :libstc)
    @setup_workload begin
        __init__()

        opts = (; (opt => _pc_value(T) for (opt, T) in CFG_OPTIONS)...)
        opts = merge(opts, (; error_dump_verbosity = STC_DUMP_VERBOSITY_NONE[]))

        @compile_workload begin
            cfg = ConfigHandle()
            set_config_opts!(cfg; opts...)
            reset_initial_sizes!(cfg)
            unsafe_free_config_handle!(cfg)

            stc_version()
            stc_version_string(false)
            stc_version_string(true)
            check_abi(false)

            # we can't transpile here (GLUtils isn't reachable from Main during precompilation),
            # so we only precompile the entry points without calling them
            for ConfTy in (STC_ConfigHandle, ConfigHandle),
                (fn, SrcTy) in ((transpile, Expr), (transpile_code, String), (transpile_file, String),
                                (unsafe_transpile, Expr), (unsafe_transpile_code, String),
                                (unsafe_transpile_file, String))
                @assert precompile(fn, (SrcTy,))
                @assert precompile(fn, (SrcTy, ConfTy))
                @assert precompile(fn, (SrcTy, ConfTy, Bool))
            end
        end
    end
end
