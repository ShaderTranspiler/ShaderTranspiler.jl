# ! NOTE
# every endpoint tries to be non-throwing by default, returning an empty handle and printing the error with @error instead of throwing
# each provides the `throw_error` arg (`false` by default) that turns these into proper exceptions
# high-level endpoints propagate `throw_error` downwards
# endpoints try to treat null handle inputs as a no-op, even if `throw_error` is `true`, high-level endpoints try to catch intermediate, unexpected null cases separately, treating them according to `throw_error`
# `throw_error` only applies to unexpected library interactions and results. the transpiler returning a result properly (even if it's an internal error result), it is NOT treated as an error, but left for the caller to resolve.

# Low-level API:
export unsafe_transpile, unsafe_transpile_code, unsafe_transpile_file, unsafe_get_transpile_result, unsafe_free_transpile_handle

# High-level API:
export transpile, transpile_code, transpile_file

export auto_overwrite_gl_utils

# If true, the transpiler wrappers will apply the pkg's internal GLUtils Module as the gl_utils_mod config parameter.
# Note that this overwrites the gl_utils_mod option of any configuration passed to a transpile endpoint, and does NOT restore it at the end!
global auto_overwrite_gl_utils::Bool = true

# Low-level API for interacting with the STC lib

"""
    unsafe_transpile(ast::Expr, cfg_handle::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, STC_ResultHandle}

Low-level endpoint for invoking the transpilation pipeline on Julia-parsed code through the underlying STC library.

Returns a transpiler status and a handle. The handle can be used to retrieve the string output with `unsafe_get_transpile_result` if status is STC_SUCCESS.
Failed transpilation produces either STC_FAILED or STC_INTERNAL_ERROR as the status, and STC_NULL_RESULT as the handle.
The caller is responsible for calling `unsafe_free_transpile_handle` on the returned handle, if it's non-null.
"""
function unsafe_transpile(ast::Expr, cfg_handle::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, STC_ResultHandle}
    cfg_handle, created_cfg = _prepare_config(cfg_handle)
    
    result_handle = Ref{STC_ResultHandle}()
    GC.@preserve ast begin
        status = ccall((LIBSTC_FN_TRANSPILE, libstc), STC_Status, (Any, STC_ConfigHandle, Ptr{STC_ResultHandle}), ast, cfg_handle, result_handle)
    end

    _finalize_config(cfg_handle, created_cfg)

    _validate_transpiler_result(throw_error, status, result_handle[], LIBSTC_FN_TRANSPILE)
    return (status, result_handle[])
end
unsafe_transpile(ast::Expr, cfg::ConfigHandle, throw_error::Bool = false)::Tuple{STC_Status, STC_ResultHandle} =
    GC.@preserve cfg unsafe_transpile(ast, cfg.value, throw_error)

"""
    unsafe_transpile_code(code::String, cfg_handle::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, STC_ResultHandle}

Low-level endpoint for invoking the transpilation pipeline on unparsed code through the underlying STC library.

Returns a transpiler status and a handle. The handle can be used to retrieve the string output with `unsafe_get_transpile_result` if status is STC_SUCCESS.
Failed transpilation produces either STC_FAILED or STC_INTERNAL_ERROR as the status, and STC_NULL_RESULT as the handle.
The caller is responsible for calling `unsafe_free_transpile_handle` on the returned handle, if it's non-null.
"""
function unsafe_transpile_code(code::String, cfg_handle::STC_ConfigHandle=STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, STC_ResultHandle}
    cfg_handle, created_cfg = _prepare_config(cfg_handle)
    
    result_handle = Ref{STC_ResultHandle}()
    GC.@preserve code begin
        status = ccall((LIBSTC_FN_TRANSPILE_CODE, libstc), STC_Status, (Cstring, STC_ConfigHandle, Ptr{STC_ResultHandle}), code, cfg_handle, result_handle)
    end

    _finalize_config(cfg_handle, created_cfg)

    _validate_transpiler_result(throw_error, status, result_handle[], LIBSTC_FN_TRANSPILE_CODE)
    return (status, result_handle[])
end
unsafe_transpile_code(code::String, cfg::ConfigHandle, throw_error::Bool = false)::Tuple{STC_Status, STC_ResultHandle} =
    GC.@preserve cfg unsafe_transpile_code(code, cfg.value, throw_error)

"""
    unsafe_transpile_file(path::String, cfg_handle::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, STC_ResultHandle}

Low-level endpoint for calling `unsafe_transpile` with the contents of a file.

Returns (STC_FAILED, STC_NULL_RESULT) if the file at the given `path` could not be read, or if it contained syntactically malformed code.
Forwards the output of `unsafe_transpile` otherwise, see its docs for argument descriptions, return details and caller responsibilities.
"""
function unsafe_transpile_file(path::String, cfg_handle::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, STC_ResultHandle}
    if !isfile(path)
        _handle_error(throw_error, ArgumentError, "Argument 'path' of unsafe_transpile_file does not point to a file on the system! (at $path)")
        return (STC_FAILED[], STC_NULL_RESULT[])
    end

    file_content = try
        read(path, String)
    catch ex
        _handle_error(throw_error, "File pointed to by 'path' argument of unsafe_transpile_file could not be read from disk! (at $path)", ex, true)
        return (STC_FAILED[], STC_NULL_RESULT[])
    end

    file_expr = try
        expr = Meta.parse("begin $file_content end")

        if Meta.isexpr(expr, :incomplete)
            if length(expr.args) != 1 || !isa(expr.args[1], Meta.ParseError)
                @error "Unexpected :incomplete Expr layout returned by Meta.parse! Dumping output instead of throwing or logging properly:"
                dump(stderr, expr)

                return (STC_FAILED[], STC_NULL_RESULT[])
            end

            throw(expr.args[1])
        end

        expr
    catch ex
        if ex isa Meta.ParseError
            _handle_error(throw_error, "Invalid Julia syntax in file at '$path'!", ex, true)
        else
            _handle_error(throw_error, "Unexpected error while parsing file at '$path'!", ex, true)
        end
        return (STC_FAILED[], STC_NULL_RESULT[])
    end

    return unsafe_transpile(file_expr, cfg_handle, throw_error)
end
unsafe_transpile_file(path::String, cfg::ConfigHandle, throw_error::Bool = false)::Tuple{STC_Status, STC_ResultHandle} =
    GC.@preserve cfg unsafe_transpile_file(path, cfg.value, throw_error)

const _EMPTY_STR::String = ""
_EMPTY_CSTR()::Cstring = Base.unsafe_convert(Cstring, _EMPTY_STR) # we don't 'const' this because otherwise precompilation bakes in an invalid pointer

"""
    unsafe_get_transpile_result(handle::STC_ResultHandle, throw_error::Bool = false)::Cstring

Low-level endpoint for obtaining a pointer to the C friendly representation of the generated code.

For valid invocations, this is guaranteed to be a valid Cstring. If `handle` is null, `C_NULL` is returned.
Invocations with invalid handles (i.e. ones that were not produced by the transpiler) are considered UB.
"""
function unsafe_get_transpile_result(handle::STC_ResultHandle, throw_error::Bool = false)::Cstring
    handle == STC_NULL_RESULT[] && return C_NULL

    result = ccall((LIBSTC_FN_GET_RESULT, libstc), Cstring, (STC_ResultHandle,), handle)
    if result == C_NULL
        _handle_error(throw_error, "NULL returned by libstc for non-null result handle! (handle: $handle)", LIBSTC_FN_GET_RESULT)
        return _EMPTY_CSTR()
    end

    return result
end

"""
    unsafe_free_transpile_handle(handle::STC_ResultHandle, throw_error::Bool = false)::Nothing

Low-level endpoint for freeing the memory storing the generated code of a transpilation.

If `handle` is null, this is a no-op.
`throw_error` currently has no effect, but is reserved to match style of other endpoints, as well as to possibly do proper validation in the future (requires libstc bookkeeping).
"""
function unsafe_free_transpile_handle(handle::STC_ResultHandle, throw_error::Bool = false)::Nothing
    handle != STC_NULL_RESULT[] && ccall((LIBSTC_FN_FREE_RESULT, libstc), Cvoid, (STC_ResultHandle,), handle)
    nothing
end

# High-level API for transpilation

"""
Private binding for safely unwrapping the string result of a transpilation.

Unwraps and frees a result handle, returning its underlying code as a String.
Non-throwing by default, returns an empty string on failure.
"""
function safe_unwrap_transpile_result(handle::STC_ResultHandle, throw_error::Bool = false)::String
    handle == STC_NULL_RESULT[] && return ""

    result_cstr = unsafe_get_transpile_result(handle, throw_error)
    @assert result_cstr != C_NULL

    try
        return unsafe_string(result_cstr)
    catch ex
        _handle_error(throw_error, "Exception while unwrapping transpiler result!", ex, true)
        return ""
    finally
        unsafe_free_transpile_handle(handle, throw_error)
    end
end

"""
    transpile(ast::Expr, cfg::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, String}

Memory-safe endpoint for invoking the transpilation pipeline on Julia-parsed code through the underlying STC library, and unwrapping its result.

Forwards the output of `unsafe_transpile`, with the STC_ResultHandle already resolved to a String upon successful transpilation.
If `throw_error` is set to `true`, any low-level errors tied to library interactions will throw runtime errors, after freeing any potentially allocated memory.
Transpilation failures (even if caused by internal errors) never throw and are returned as (status, "").
"""
function transpile(ast::Expr, cfg::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, String}
    (status, handle) = unsafe_transpile(ast, cfg, throw_error)
    return (status, safe_unwrap_transpile_result(handle, throw_error))
end
transpile(ast::Expr, cfg::ConfigHandle, throw_error::Bool = false)::Tuple{STC_Status, String} =
    GC.@preserve cfg transpile(ast, cfg.value, throw_error)

"""
    transpile_code(code::String, cfg::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, String}

Memory-safe endpoint for invoking the transpilation pipeline on unparsed code through the underlying STC library, and unwrapping its result.

Forwards the output of `unsafe_transpile_code`, with the STC_ResultHandle already resolved to a String upon successful transpilation.
If `throw_error` is set to `true`, any low-level errors tied to library interactions will throw runtime errors, after freeing any potentially allocated memory.
Transpilation failures (even if caused by internal errors) never throw and are returned as (status, "").
"""
function transpile_code(code::String, cfg::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, String}
    (status, handle) = unsafe_transpile_code(code, cfg, throw_error)
    return (status, safe_unwrap_transpile_result(handle, throw_error))
end
transpile_code(code::String, cfg::ConfigHandle, throw_error::Bool = false)::Tuple{STC_Status, String} =
    GC.@preserve cfg transpile_code(code, cfg.value, throw_error)

"""
    transpile_file(path::String, cfg::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, String}

Memory-safe endpoint for invoking the transpilation pipeline on the contents of a file through the underlying STC library, and unwrapping its result.
For the arguments and return type descriptions see the docs of `unsafe_transpile_file`.
"""
function transpile_file(path::String, cfg::STC_ConfigHandle = STC_NULL_CONFIG[], throw_error::Bool = false)::Tuple{STC_Status, String}
    (status, handle) = unsafe_transpile_file(path, cfg, throw_error)
    return (status, safe_unwrap_transpile_result(handle, throw_error))
end
transpile_file(path::String, cfg::ConfigHandle, throw_error::Bool = false)::Tuple{STC_Status, String} =
    GC.@preserve cfg transpile_file(path, cfg.value, throw_error)

# Internal helpers

# ! ExTy has to have a constructor matching `ExTy(msg, args...)`
function _handle_error(throw_error::Bool, ::Type{ExTy}, msg::String, args...) where {ExTy <: Exception}
    throw_error && throw(ExTy(msg, args...))
    @error msg
    nothing
end

function _handle_error(throw_error::Bool, msg::String, lib_fn::Union{Symbol, Nothing} = nothing)::Nothing
    if (!throw_error && lib_fn !== nothing) msg *= " (while calling function $lib_fn of libstc)" end
    _handle_error(throw_error, STCLibError, msg, lib_fn)
    nothing
end

function _handle_error(throw_error::Bool, msg::String, ex::Exception, caught::Bool = false)::Nothing
    @error msg # we always print message here, since 'ex' might be a propagated Exception with a completely separate error message
    throw_error && (caught ? rethrow(ex) : throw(ex))
    nothing
end

function _validate_transpiler_result(throw_error::Bool, status::STC_Status, handle::STC_ResultHandle, lib_fn::Union{Symbol, Nothing} = nothing)::Bool
    valid = true

    if !(LibUtils.STC_STATUS_FIRST[] <= status <= LibUtils.STC_STATUS_LAST[])
        _handle_error(throw_error, "Invalid STC_Status value returned!", lib_fn)
        valid = false
    end

    if status == STC_SUCCESS[] && handle == STC_NULL_RESULT[]
        _handle_error(throw_error, "Null result handle returned for a successful transpilation!", lib_fn)
        valid = false
    end

    if status != STC_SUCCESS[] && handle != STC_NULL_RESULT[]
        throw_error && unsafe_free_transpile_handle(handle, throw_error) # assume handle is not junk and free before returning
        _handle_error(throw_error, "Non-null result handle returned for a failed transpilation!", lib_fn)
        valid = false
    end

    return valid
end

function _prepare_config(cfg::STC_ConfigHandle)::Tuple{STC_ConfigHandle, Bool}
    !auto_overwrite_gl_utils && return (cfg, false)
    
    created_cfg::Bool = false
    if cfg == STC_NULL_CONFIG[]
        cfg = Config.unsafe_create_config_handle()
        created_cfg = true
    end

    Config.set_gl_utils_mod!(cfg, GLUtils)
    return (cfg, created_cfg)    
end

# we cannot restore the old value for now, since libstc doesn't expose config getters through the C library
function _finalize_config(cfg::STC_ConfigHandle, created_for_transpile::Bool)::Nothing
    !created_for_transpile && return nothing
    Config.unsafe_free_config_handle!(cfg)
end
_finalize_config(prepare_config_result::Tuple{STC_ConfigHandle, Bool})::Nothing = _finalize_config(prepare_config_result...)
