"""
    STCLibError(msg::String, lib_fn_name::Union{Symbol,Nothing} = nothing, append_general_msg::Bool = true)

Exception thrown when an unexpected error occurs during interaction with the base stc transpiler library.

This error is intended to wrap low-level failures originating from the C library boundary.
It is not meant to replace or wrap `ccall`'s thrown errors, only invalid returns from the library (e.g. C_NULL) and such.

In most cases, these failures indicate either:
- an internal error within the stc library,
- invalid or inconsistent state passed across the FFI boundary, or
- resource exhaustion (e.g. system is out of memory)

# Fields
- `msg::String`: Human-readable error message describing the failure.
- `lib_fn_name::Union{Symbol, Nothing}`: Optionally, the name of the lib function that was called, or `nothing` if the error is not tied to a specific call.
- if `append_general_msg` is `true`, a generic explanation about possible causes is appended to `msg`.
"""
struct STCLibError <: Exception
    msg::String
    lib_fn_name::Union{Symbol, Nothing}

    function STCLibError(msg::String, lib_fn_name::Union{Symbol, Nothing} = nothing, append_general_msg::Bool = true)
        if append_general_msg
            !endswith(msg, ' ') && (msg *= ' ')
            msg *= "This error indicates some internal error of the underlying libstc binary, or ShaderTranspiler's low-level wrapping logic."
        end

        new(msg, lib_fn_name)
    end

    STCLibError(lib_fn_name::Symbol) =
        STCLibError("Unexpected library error when calling function $lib_fn_name of the underlying libstc binary.", lib_fn_name, true)
end
