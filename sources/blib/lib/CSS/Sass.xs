// Copyright © 2013 David Caldwell.
//
// This library is free software; you can redistribute it and/or modify
// it under the same terms as Perl itself, either Perl version 5.12.4 or,
// at your option, any later version of Perl 5 you may have available.

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>

#include "ppport.h"

#include "sass_interface.h"

#define hv_fetch_key(hv, key, lval)     hv_fetch((hv), (key), sizeof(key)-1, (lval))
#define hv_store_key(hv, key, sv, hash) hv_store((hv), (key), sizeof(key)-1, (sv), (hash))

#define Constant(c) newCONSTSUB(stash, #c, newSViv(c))

char *safe_svpv(SV *sv, char *_default)
{
    size_t length;
    if (!SvOK(sv)) return _default;
    char *str = SvPV(sv, length);
    if (memchr(str, 0, length+1)) // NULL Terminated?
        return str;
    return _default;
}

static inline IV sviv(SV *sv) { return SvIV(sv); } // un-macro-ized version of SvIV
static inline NV svnv(SV *sv) { return SvNV(sv); } // un-macro-ized version of SvNV

SV *sv_from_sass_value(union Sass_Value val)
{
    AV *perl = newAV();
    av_push(perl, newSViv(val.unknown.tag));
    switch(val.unknown.tag) {
        case SASS_BOOLEAN:
            av_push(perl, newSViv(val.boolean.value));
            break;
        case SASS_NUMBER:
            av_push(perl, newSViv(val.number.value));
            av_push(perl, newSVpv(val.number.unit, 0));
            break;
        case SASS_COLOR:
            av_push(perl, newSVnv(val.color.r));
            av_push(perl, newSVnv(val.color.g));
            av_push(perl, newSVnv(val.color.b));
            av_push(perl, newSVnv(val.color.a));
            break;
        case SASS_STRING:
            av_push(perl, newSVpv(val.string.value, 0));
            break;
        case SASS_LIST: {
            int i;
            for (i=0; i<val.list.length; i++)
                av_push(perl, sv_from_sass_value(val.list.values[i]));
        }   break;
        case SASS_ERROR:
            av_push(perl, newSVpv(val.error.message, 0));
            break;
        default:
            av_push(perl, newSVpvf("BUG: This Sass_Value is not handled yet (tag=%d).",val.unknown.tag));
            break;
    }
    return newRV_noinc((SV*) perl);
}
union Sass_Value make_sass_error_f(char *format,...)
{
    va_list ap;
    va_start(ap, format);
    char msg[100];
    vsnprintf(msg, sizeof(msg), format, ap);
    va_end(ap);
    union Sass_Value err = make_sass_error(msg ? msg : format);
    return err;
}
union Sass_Value sass_value_from_sv(SV *sv)
{
    if (!SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVAV)
        return make_sass_error_f("perl type must be an arrayref (SvTYPE=%u)", (unsigned)SvTYPE(SvRV(sv)));

    AV *av = (AV*)SvRV(sv);
    switch (sviv(*av_fetch(av, 0, false))) {
        case SASS_BOOLEAN:    return make_sass_boolean(sviv(*av_fetch(av, 1, false)));
        case SASS_NUMBER:     return make_sass_number(svnv(*av_fetch(av, 1, false)),
                                                      safe_svpv(*av_fetch(av, 2, false), ""));
        case SASS_COLOR:      return make_sass_color(svnv(*av_fetch(av, 1, false)),
                                                     svnv(*av_fetch(av, 2, false)),
                                                     svnv(*av_fetch(av, 3, false)),
                                                     svnv(*av_fetch(av, 4, false)));
        case SASS_STRING:     return make_sass_string(safe_svpv(*av_fetch(av, 1, false), ""));
        case SASS_ERROR:      return make_sass_error(safe_svpv(*av_fetch(av, 1, false), ""));

        case SASS_LIST: {
            enum Sass_Separator sep = sviv(*av_fetch(av, 1, false));
            union Sass_Value list = make_sass_list(av_len(av)+1-2, sep);
            int i;
            for (i=0; i<list.list.length; i++)
                list.list.values[i] = sass_value_from_sv(*av_fetch(av, i+2, false));
            return list;
        }
    }

    return make_sass_error_f("Unknown sass_type (tag=%u)", (unsigned)sviv(*av_fetch(av, 0, false)));
}

union Sass_Value sass_function_callback(union Sass_Value s_args, void *cookie)
{
    dSP;
    SV *perl_callback = cookie;
    int i;

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    XPUSHs(perl_callback);
    for (i=0; i<s_args.list.length; i++)
        XPUSHs(sv_2mortal(sv_from_sass_value(s_args.list.values[i])));
    PUTBACK;

    int count = call_pv("CSS::Sass::sass_function_callback", G_SCALAR);

    SPAGAIN;
    SV *ret_sv = NULL;
    if (count == 1)
        ret_sv = POPs;
    PUTBACK;

    union Sass_Value ret_val = count == 1 ? sass_value_from_sv(ret_sv)
                                          : make_sass_error_f("%s:%d %s: Oh no, a bug! count=%d\n", __FILE__, __LINE__, __func__, count); // should never happen!


    FREETMPS;
    LEAVE;

    return ret_val;
}


MODULE = CSS::Sass		PACKAGE = CSS::Sass

BOOT:
{
    HV *stash = gv_stashpv("CSS::Sass", 0);
    Constant(SASS_STYLE_NESTED);
    //Constant(stash, SASS_STYLE_EXPANDED); // not implemented in libsass yet
    //Constant(stash, SASS_STYLE_COMPACT);  // not implemented in libsass yet
    Constant(SASS_STYLE_COMPRESSED);

    Constant(SASS_SOURCE_COMMENTS_DEFAULT);
    Constant(SASS_SOURCE_COMMENTS_MAP);

    Constant(SASS_BOOLEAN);
    Constant(SASS_NUMBER);
    Constant(SASS_COLOR);
    Constant(SASS_STRING);
    Constant(SASS_LIST);
    Constant(SASS_ERROR);

    Constant(SASS_COMMA);
    Constant(SASS_SPACE);

		// sass2scss constants
    Constant(SASS2SCSS_PRETTIFY_0);
    Constant(SASS2SCSS_PRETTIFY_1);
    Constant(SASS2SCSS_PRETTIFY_2);
    Constant(SASS2SCSS_PRETTIFY_3);
    // more options for sass2scss
    Constant(SASS2SCSS_KEEP_COMMENT);
    Constant(SASS2SCSS_STRIP_COMMENT);
    Constant(SASS2SCSS_CONVERT_COMMENT);
}

HV*
compile_sass(input_string, options)
             char *input_string
             HV *options
    CODE:
        RETVAL = newHV();
        sv_2mortal((SV*)RETVAL);
    {
        struct sass_context *ctx = sass_new_context();
        char error[100] = "";
        ctx->source_string = input_string;
        SV **input_path_sv      = hv_fetch_key(options, "input_path",      false);
        SV **output_path_sv     = hv_fetch_key(options, "output_path",     false);
        SV **output_style_sv    = hv_fetch_key(options, "output_style",    false);
        SV **source_comments_sv = hv_fetch_key(options, "source_comments", false);
        SV **include_paths_sv   = hv_fetch_key(options, "include_paths",   false);
        SV **precision_sv       = hv_fetch_key(options, "precision",       false);
        SV **image_path_sv      = hv_fetch_key(options, "image_path",      false);
        SV **source_map_file_sv = hv_fetch_key(options, "source_map_file", false);
        SV **sass_functions_sv  = hv_fetch_key(options, "sass_functions",  false);
        if (input_path_sv)
            ctx->input_path = safe_svpv(*input_path_sv, "");
        if (output_path_sv)
            ctx->output_path = safe_svpv(*output_path_sv, "");
        if (output_style_sv)
            ctx->options.output_style = SvUV(*output_style_sv);
        if (source_comments_sv)
            ctx->options.source_comments = SvUV(*source_comments_sv);
        if (include_paths_sv)
            ctx->options.include_paths = safe_svpv(*include_paths_sv, "");
        if (precision_sv)
            ctx->options.precision = SvUV(*precision_sv);
        if (image_path_sv)
            ctx->options.image_path = safe_svpv(*image_path_sv, "");
        if (source_map_file_sv)
            ctx->source_map_file = safe_svpv(*source_map_file_sv, "");
        if (sass_functions_sv) {
            int i;
            AV* sass_functions_av;
            if (!SvROK(*sass_functions_sv) || SvTYPE(SvRV(*sass_functions_sv)) != SVt_PVAV) {
                snprintf(error, sizeof(error), "sass_functions should be an arrayref (SvTYPE=%u)", (unsigned)SvTYPE(SvRV(*sass_functions_sv)));
                goto fail;
            }
            sass_functions_av = (AV*)SvRV(*sass_functions_sv);

            ctx->c_functions = calloc(sizeof(struct Sass_C_Function_Descriptor), av_len(sass_functions_av) + 1/*av_len() is $#av*/ + 1/*null terminated array*/);
            if (!ctx->c_functions) {
                snprintf(error, sizeof(error), "couldn't alloc memory for c_functions");
                goto fail;
            }
            for (i=0; i<=av_len(sass_functions_av); i++) {
                SV** entry_sv = av_fetch(sass_functions_av, i, false);
                AV* entry_av;
                if (!SvROK(*entry_sv) || SvTYPE(SvRV(*entry_sv)) != SVt_PVAV) {
                    snprintf(error, sizeof(error), "each sass_function entry should be an arrayref (SvTYPE=%u)", (unsigned)SvTYPE(SvRV(*entry_sv)));
                    goto fail;
                }
                entry_av = (AV*)SvRV(*entry_sv);

                SV **sig_sv = av_fetch(entry_av, 0, false);
                SV **sub_sv = av_fetch(entry_av, 1, false);

                ctx->c_functions[i].signature = safe_svpv(*sig_sv, "");
                ctx->c_functions[i].function = sass_function_callback;
                ctx->c_functions[i].cookie = *sub_sv;
            }
        }

        sass_compile(ctx); // Always returns zero. What's the point??

      fail:
        hv_store_key(RETVAL, "error_status", newSViv(ctx->error_status || !!*error), 0);
        hv_store_key(RETVAL, "output_string", ctx->output_string ? newSVpv(ctx->output_string, 0) : newSV(0), 0);
        // hv_store_key(RETVAL, "source_map_file", ctx->source_map_file ? newSVpv(ctx->source_map_file, 0) : newSV(0), 0);
        hv_store_key(RETVAL, "source_map_string", ctx->source_map_string ? newSVpv(ctx->source_map_string, 0) : newSV(0), 0);
        hv_store_key(RETVAL, "error_message", *error             ? newSVpv(error, 0)              :
                                              ctx->error_message ? newSVpv(ctx->error_message, 0) : newSV(0), 0);

        sass_free_context(ctx);
    }
    OUTPUT:
             RETVAL


HV*
compile_sass_file(input_path, options)
             char *input_path
             HV *options
    CODE:
        RETVAL = newHV();
        sv_2mortal((SV*)RETVAL);
    {
        struct sass_file_context *ctx = sass_new_file_context();
        char error[100] = "";
        ctx->input_path = input_path;
        SV **output_path_sv     = hv_fetch_key(options, "output_path",     false);
        SV **output_style_sv    = hv_fetch_key(options, "output_style",    false);
        SV **source_comments_sv = hv_fetch_key(options, "source_comments", false);
        SV **include_paths_sv   = hv_fetch_key(options, "include_paths",   false);
        SV **precision_sv       = hv_fetch_key(options, "precision",       false);
        SV **image_path_sv      = hv_fetch_key(options, "image_path",      false);
        SV **source_map_file_sv = hv_fetch_key(options, "source_map_file", false);
        SV **sass_functions_sv  = hv_fetch_key(options, "sass_functions",  false);
        if (output_path_sv)
            ctx->output_path = safe_svpv(*output_path_sv, "");
        if (output_style_sv)
            ctx->options.output_style = SvUV(*output_style_sv);
        if (source_comments_sv)
            ctx->options.source_comments = SvUV(*source_comments_sv);
        if (include_paths_sv)
            ctx->options.include_paths = safe_svpv(*include_paths_sv, "");
        if (precision_sv)
            ctx->options.precision = SvUV(*precision_sv);
        if (image_path_sv)
            ctx->options.image_path = safe_svpv(*image_path_sv, "");
        if (source_map_file_sv)
            ctx->source_map_file = safe_svpv(*source_map_file_sv, "");
        if (sass_functions_sv) {
            int i;
            AV* sass_functions_av;
            if (!SvROK(*sass_functions_sv) || SvTYPE(SvRV(*sass_functions_sv)) != SVt_PVAV) {
                snprintf(error, sizeof(error), "sass_functions should be an arrayref (SvTYPE=%u)", (unsigned)SvTYPE(SvRV(*sass_functions_sv)));
                goto fail;
            }
            sass_functions_av = (AV*)SvRV(*sass_functions_sv);

            ctx->c_functions = calloc(sizeof(struct Sass_C_Function_Descriptor), av_len(sass_functions_av) + 1/*av_len() is $#av*/ + 1/*null terminated array*/);
            if (!ctx->c_functions) {
                snprintf(error, sizeof(error), "couldn't alloc memory for c_functions");
                goto fail;
            }
            for (i=0; i<=av_len(sass_functions_av); i++) {
                SV** entry_sv = av_fetch(sass_functions_av, i, false);
                AV* entry_av;
                if (!SvROK(*entry_sv) || SvTYPE(SvRV(*entry_sv)) != SVt_PVAV) {
                    snprintf(error, sizeof(error), "each sass_function entry should be an arrayref (SvTYPE=%u)", (unsigned)SvTYPE(SvRV(*entry_sv)));
                    goto fail;
                }
                entry_av = (AV*)SvRV(*entry_sv);

                SV **sig_sv = av_fetch(entry_av, 0, false);
                SV **sub_sv = av_fetch(entry_av, 1, false);

                ctx->c_functions[i].signature = safe_svpv(*sig_sv, "");
                ctx->c_functions[i].function = sass_function_callback;
                ctx->c_functions[i].cookie = *sub_sv;
            }
        }

        sass_compile_file(ctx); // Always returns zero. What's the point??

      fail:
        hv_store_key(RETVAL, "error_status", newSViv(ctx->error_status || !!*error), 0);
        hv_store_key(RETVAL, "output_string", ctx->output_string ? newSVpv(ctx->output_string, 0) : newSV(0), 0);
        // hv_store_key(RETVAL, "source_map_file", ctx->source_map_file ? newSVpv(ctx->source_map_file, 0) : newSV(0), 0);
        hv_store_key(RETVAL, "source_map_string", ctx->source_map_string ? newSVpv(ctx->source_map_string, 0) : newSV(0), 0);
        hv_store_key(RETVAL, "error_message", *error             ? newSVpv(error, 0)              :
                                              ctx->error_message ? newSVpv(ctx->error_message, 0) : newSV(0), 0);

        sass_free_file_context(ctx);
    }
    OUTPUT:
             RETVAL

const char*
sass2scss(sass, options = SASS2SCSS_PRETTIFY_1)
             char *sass
             int options
    CODE:
        sv_2mortal((SV*)RETVAL);
    {

        RETVAL = sass2scss(sass, options);

        // seems to be removed automatically
        // if enabled I get "double free" error
        // safefree (sass);

    }
    OUTPUT:
             RETVAL

