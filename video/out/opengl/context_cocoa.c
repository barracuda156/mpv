/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <OpenGL/OpenGL.h>
#include <AvailabilityMacros.h>
#include <dlfcn.h>
#include "options/m_config.h"
#include "video/out/cocoa_common.h"
#include "context.h"
#include "osdep/mac/app_bridge.h"

struct priv {
    GL gl;
    void (GLAPIENTRY *Flush)(void);
    CGLPixelFormatObj pix;
    CGLContextObj ctx;

    struct macos_opts *macos_opts;
};

static int set_swap_interval(int enabled)
{
    CGLContextObj ctx = CGLGetCurrentContext();
    CGLError err = CGLSetParameter(ctx, kCGLCPSwapInterval, &enabled);
    return (err == kCGLNoError) ? 0 : -1;
}

static void glFlushDummy(void) { }

static void *cocoa_glgetaddr(const char *s)
{
    void *ret = NULL;
    void *handle = dlopen(
        "/System/Library/Frameworks/OpenGL.framework/OpenGL",
        RTLD_LAZY | RTLD_LOCAL);
    if (!handle)
        return NULL;
    ret = dlsym(handle, s);
    dlclose(handle);
    return ret;
}

// On 10.5/10.6 there is exactly one OpenGL profile (legacy/compatibility);
// kCGLPFAOpenGLProfile and the CGLOpenGLProfile enum are 10.7+ and do not
// exist in these SDKs. So no profile attribute is added at all (api-floor §4).
//
// kCGLPFASupportsAutomaticGraphicsSwitching (dual-GPU laptops) is also dropped
// entirely: it is meaningless on PPC hardware (no switchable GPU) and, being an
// enum constant rather than a macro, its presence cannot be detected in the
// preprocessor across SDK vintages. This also makes macos-force-dedicated-gpu
// a no-op here, which is correct on this hardware.
static CGLError create_cgl_context(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;

    CGLPixelFormatAttribute attrs[] = {
        // ordered by the inverse order of the most probably rejected
        // attribute, to preserve the fallback code
        kCGLPFAAccelerated,
        // kCGLPFAAllowOfflineRenderers is 10.5+; omit it on 10.4.
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1050
        kCGLPFAAllowOfflineRenderers,
#endif
        0
    };

    GLint npix;
    CGLError err;
    int supported_attribute = MP_ARRAY_SIZE(attrs)-1;

    err = CGLChoosePixelFormat(attrs, &p->pix, &npix);
    while (err == kCGLBadAttribute && supported_attribute > 1) {
        // kCGLPFAAllowOfflineRenderers may be rejected under further
        // restrictions; drop it and retry with just kCGLPFAAccelerated.
        attrs[--supported_attribute] = 0;
        err = CGLChoosePixelFormat(attrs, &p->pix, &npix);
    }

    if (err != kCGLNoError) {
        MP_ERR(ctx->vo, "error creating CGL pixel format: %s (%d)\n",
               CGLErrorString(err), err);
        goto error_out;
    }

    err = CGLCreateContext(p->pix, 0, &p->ctx);

error_out:
    return err;
}

static bool create_gl_context(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    GL *gl = &p->gl;
    CGLError err;

    err = create_cgl_context(ctx);

    if (err != kCGLNoError) {
        MP_FATAL(ctx->vo, "error creating CGL context: %s (%d)\n",
                 CGLErrorString(err), err);
        return false;
    }

    vo_cocoa_set_opengl_ctx(ctx->vo, p->ctx);
    CGLSetCurrentContext(p->ctx);

    if (ctx->opts.want_alpha)
        CGLSetParameter(p->ctx, kCGLCPSurfaceOpacity, &(GLint){0});

    mpgl_load_functions(gl, (void *)cocoa_glgetaddr, NULL, ctx->vo->log);
    gl->SwapInterval = set_swap_interval;
    p->Flush = gl->Flush;
    gl->Flush = glFlushDummy;

    CGLReleasePixelFormat(p->pix);

    return true;
}

static void cocoa_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    ra_gl_ctx_uninit(ctx);
    CGLReleaseContext(p->ctx);
    vo_cocoa_uninit(ctx->vo);
}

static void cocoa_swap_buffers(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    vo_cocoa_swap_buffers(ctx->vo);
    p->Flush();
}

static bool cocoa_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    GL *gl = &p->gl;
    p->macos_opts = mp_get_config_group(ctx, ctx->global, &macos_conf);
    vo_cocoa_init(ctx->vo);

    if (!create_gl_context(ctx))
        goto fail;

    struct ra_ctx_params params = {
        .swap_buffers = cocoa_swap_buffers,
    };

    if (!ra_gl_ctx_init(ctx, gl, params))
        goto fail;

    return true;

fail:
    cocoa_uninit(ctx);
    return false;
}

static void resize(struct ra_ctx *ctx)
{
    ra_gl_ctx_resize(ctx->swapchain, ctx->vo->dwidth, ctx->vo->dheight, 0);
}

static bool cocoa_reconfig(struct ra_ctx *ctx)
{
    vo_cocoa_config_window(ctx->vo);
    resize(ctx);
    return true;
}

static int cocoa_control(struct ra_ctx *ctx, int *events, int request,
                         void *arg)
{
    int ret = vo_cocoa_control(ctx->vo, events, request, arg);
    if (*events & VO_EVENT_RESIZE)
        resize(ctx);
    return ret;
}

const struct ra_ctx_fns ra_ctx_cocoa = {
    .type           = "opengl",
    .name           = "cocoa",
    .description    = "Cocoa/NSOpenGL (legacy)",
    .init           = cocoa_init,
    .reconfig       = cocoa_reconfig,
    .control        = cocoa_control,
    .uninit         = cocoa_uninit,
};
