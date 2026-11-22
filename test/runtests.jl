using Test
using ShaderTranspiler
using GLUtils

const LibMod = ShaderTranspiler
const ConfMod = LibMod.Config

@testset "ShaderTranspiler.jl" begin
    @testset "Version" begin
        @test_nowarn LibMod.check_abi(false) # this isn't really need in Julia 1.12+, but cannot hurt
        
        @test stc_version().major == pkgversion(LibMod).major
        @test stc_version().minor == pkgversion(LibMod).minor
        @test stc_version().patch == pkgversion(LibMod).patch

        ver_str_no_commit = stc_version_string(false)
        @test !isempty(ver_str_no_commit)
        dot_count = findall('.', ver_str_no_commit) |> length
        has_rc = findfirst("-rc.", ver_str_no_commit) !== nothing
        @test dot_count == 2 || (dot_count == 3 && has_rc)
        
        ver_str_with_commit = stc_version_string(true)
        @test !isempty(ver_str_with_commit)
        @test startswith(ver_str_with_commit, ver_str_no_commit)
        @test length(ver_str_with_commit) > length(ver_str_no_commit)
    end

    @testset "Globals" begin
        # typedefs
        @test isdefined(LibMod, :STC_Status)
        @test isdefined(LibMod, :STC_ResultHandle)
        @test isdefined(LibMod, :STC_ConfigHandle)
        @test isdefined(LibMod, :STC_DumpVerbosity)

        # check that symbols are loaded from libstc properly (without hardcoding every value except zero)
        @test LibMod.STC_STATUS_FIRST[]   == zero(STC_Status)
        @test STC_SUCCESS[]        == zero(STC_Status)
        @test STC_FAILED[]         != zero(STC_Status)
        @test STC_INTERNAL_ERROR[] != zero(STC_Status)
        @test LibMod.STC_STATUS_LAST[]    != zero(STC_Status)
        @test all(ref -> LibMod.STC_STATUS_FIRST[] <= ref[] <= LibMod.STC_STATUS_LAST[],
                  (STC_SUCCESS, STC_FAILED, STC_INTERNAL_ERROR))

        @test LibMod.STC_DUMP_VERBOSITY_FIRST[]   == zero(STC_DumpVerbosity)
        @test STC_DUMP_VERBOSITY_NONE[]    == zero(STC_DumpVerbosity)
        @test STC_DUMP_VERBOSITY_PARTIAL[] != zero(STC_DumpVerbosity)
        @test STC_DUMP_VERBOSITY_VERBOSE[] != zero(STC_DumpVerbosity)
        @test LibMod.STC_DUMP_VERBOSITY_LAST[]    != zero(STC_DumpVerbosity)
        @test all(ref -> LibMod.STC_DUMP_VERBOSITY_FIRST[] <= ref[] <= LibMod.STC_DUMP_VERBOSITY_LAST[],
                  (STC_DUMP_VERBOSITY_NONE, STC_DUMP_VERBOSITY_PARTIAL, STC_DUMP_VERBOSITY_VERBOSE))

        @test STC_NULL_RESULT[] isa STC_ResultHandle
        @test STC_NULL_CONFIG[] isa STC_ConfigHandle
    end

    # we mostly check for the lib not throwing any errors here
    @testset "Config API" begin
        cfg = ConfigHandle()
        @test cfg.value != STC_NULL_CONFIG[]

        cfg2 = ConfMod.unsafe_create_config_handle()
        @test cfg2 != STC_NULL_CONFIG[]

        cfg3 = ConfigHandle(STC_NULL_CONFIG[])
        @test cfg3.value == STC_NULL_CONFIG[]

        # tests underlying setters as well
        set_config_opts!(cfg;
            use_tabs=true,
            code_gen_indent=UInt16(2),
            forward_fns=false,
            dump_parsed=true,
            dump_lowered=true,
            warn_on_jl_sema_query=true,
            local_size=UInt32.((1, 2, 3))
        )

        ConfMod.set_error_dump_verbosity!(cfg, ShaderTranspiler.STC_DUMP_VERBOSITY_NONE[])
        ConfMod.set_error_dump_verbosity!(cfg.value, ShaderTranspiler.STC_DUMP_VERBOSITY_NONE[])
        ConfMod.set_error_dump_verbosity!(cfg, ShaderTranspiler.STC_DUMP_VERBOSITY_PARTIAL[])
        ConfMod.set_error_dump_verbosity!(cfg.value, ShaderTranspiler.STC_DUMP_VERBOSITY_PARTIAL[])
        ConfMod.set_error_dump_verbosity!(cfg, ShaderTranspiler.STC_DUMP_VERBOSITY_VERBOSE[])
        ConfMod.set_error_dump_verbosity!(cfg.value, ShaderTranspiler.STC_DUMP_VERBOSITY_VERBOSE[])

        @test_throws DomainError ConfMod.set_error_dump_verbosity!(cfg, LibMod.STC_DUMP_VERBOSITY_LAST[] + one(STC_DumpVerbosity))
        @test_throws DomainError ConfMod.set_error_dump_verbosity!(cfg, typemax(STC_DumpVerbosity))

        ConfMod.set_local_size!(cfg, UInt32.((0, 0, 0)))
        ConfMod.set_local_size!(cfg, UInt32.((1, 2, 3)))

        unsafe_free_config_handle!(cfg)
        @test cfg.value == STC_NULL_CONFIG[]

        @test_nowarn ConfMod.unsafe_free_config_handle!(cfg2)
        @test_nowarn ConfMod.unsafe_free_config_handle!(cfg3) # no-op
    end

    # this doesn't aim to test transpilation results, only their success
    @testset "Transpilation API" begin
        successful_transpile(::Any)::Bool = false
        successful_transpile(result::Tuple{STC_Status, String})::Bool = result[1] == STC_SUCCESS[] && !isempty(result[2])

        failed_transpile(::Any)::Bool = false
        failed_transpile(result::Tuple{STC_Status, String})::Bool = result[1] == STC_FAILED[] && isempty(result[2])

        valid_ast = quote
            function main()
                x = vec3(0) .+ vec3(1)
            end
        end

        res = transpile(valid_ast)
        @test successful_transpile(res)

        invalid_ast = quote
            function main()
                x = 1
                x = vec3(0)
            end
        end

        @test_warn "type mismatch" res = transpile(invalid_ast)
        @test failed_transpile(res)

        # test if config works
        cfg = ConfigHandle()
        set_config_opts!(cfg; use_tabs=true)

        res = transpile(valid_ast, cfg)
        @test successful_transpile(res)
        res = transpile(valid_ast, cfg.value)
        @test successful_transpile(res)

        # fn forwarding allows non-target builtin functions to be transpiled
        # if they can be found on the Julia side, so e.g. println here works
        # with fn forwarding ONLY
        fn_fwd_ast = quote
            function main()
                println(2)
            end
        end

        unsafe_free_config_handle!(cfg)
        cfg = ConfigHandle()

        set_config_opts!(cfg; forward_fns=true)

        @test_nowarn res = transpile(fn_fwd_ast, cfg)
        @test successful_transpile(res)

        set_config_opts!(cfg; forward_fns=false)
        @test_warn "function forwarding" res = transpile(fn_fwd_ast, cfg)
        @test failed_transpile(res)

        unsafe_free_config_handle!(cfg)
        cfg = ConfigHandle()

        # uses 1234 to guarantee this is not the default setting
        set_config_opts!(cfg; target_version="1234 core")

        res = transpile(valid_ast, cfg)
        @test successful_transpile(res)
        @test startswith(res[2], "#version 1234 core")

        # creates a temporary file to read
        mktemp() do path, io
            write(io, "function main() x = 2 end")
            close(io)

            res = transpile_file(path, cfg)
            @test successful_transpile(res)
            res = transpile_file(path, cfg.value)
            @test successful_transpile(res)
        end
        
        @test_warn "does not point to a file on the system" res = transpile_file("some_path_that_is_very_likely_to_not_exist_so_please_do_not_create_a_file_named_like_this.jl", cfg.value)
        @test failed_transpile(res)
        @test_throws ArgumentError transpile_file("some_path_that_is_very_likely_to_not_exist_so_please_do_not_create_a_file_named_like_this.jl", cfg.value, true)

        res = transpile_code("begin x = 2 end", cfg)
        @test successful_transpile(res)
        res = transpile_code("begin x = 2 end", cfg.value)
        @test successful_transpile(res)
    end

    # these are no-ops on the Julia side, so we just check that they correctly unwrap
    @testset "Qualifier Macros" begin
        non_lq_quals = [
            :const, :in, :out, :inout, :attribute, :uniform, :varying, :buffer,
            :shared, :centroid, :sample, :patch, :smooth, :flat, :noperspective,
            :lowp, :mediump, :highp, :invariant, :precise, :subroutine, :coherent,
            :volatile, :restrict, :readonly, :writeonly
        ]

        # we have to create temporary globals, which is not great but it's only for testing
        for qual in non_lq_quals
            qual_macro = Symbol("@gl_", qual)
            tmp_sym = gensym(string(qual, "_test"))

            assign_expr = Expr(:macrocall, qual_macro, LineNumberNode(0), :($(tmp_sym)::Int = 10))
            eval(assign_expr)

            @test eval(:($tmp_sym == 10))
        end

        # Test the layout macro
        @test_nowarn @eval @gl_layout(location = 0, global out_color::Float32 = 1.0)
    end

end
