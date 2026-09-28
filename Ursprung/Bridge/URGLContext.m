// SPDX-License-Identifier: GPL-3.0-or-later

#define GL_SILENCE_DEPRECATION 1

#import "URGLContext.h"

#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <dlfcn.h>

@implementation URGLContext {
    CGLContextObj _context;
    GLuint _fbo;
    GLuint _colorTexture;
    GLuint _depthStencil;
    BOOL _depth;
    BOOL _stencil;
    uint8_t *_scratch;
    size_t _scratchSize;
}

- (nullable instancetype)initWithCoreProfile:(BOOL)coreProfile
                                       depth:(BOOL)depth
                                     stencil:(BOOL)stencil
                                       error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _depth = depth;
    _stencil = stencil;

    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)(coreProfile ? kCGLOGLPVersion_GL4_Core : kCGLOGLPVersion_Legacy),
        kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
        kCGLPFADepthSize, (CGLPixelFormatAttribute)24,
        kCGLPFAStencilSize, (CGLPixelFormatAttribute)8,
        kCGLPFAAccelerated,
        kCGLPFAAllowOfflineRenderers,
        (CGLPixelFormatAttribute)0,
    };

    CGLPixelFormatObj pixelFormat = NULL;
    GLint count = 0;
    CGLError result = CGLChoosePixelFormat(attributes, &pixelFormat, &count);
    if (result != kCGLNoError || !pixelFormat) {
        if (error) *error = [NSError errorWithDomain:@"Ursprung.GL" code:result
                                            userInfo:@{NSLocalizedDescriptionKey: @"No suitable OpenGL pixel format."}];
        return nil;
    }
    result = CGLCreateContext(pixelFormat, NULL, &_context);
    CGLReleasePixelFormat(pixelFormat);
    if (result != kCGLNoError || !_context) {
        if (error) *error = [NSError errorWithDomain:@"Ursprung.GL" code:result
                                            userInfo:@{NSLocalizedDescriptionKey: @"Could not create an OpenGL context."}];
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_context) {
        CGLSetCurrentContext(_context);
        if (_fbo) glDeleteFramebuffers(1, &_fbo);
        if (_colorTexture) glDeleteTextures(1, &_colorTexture);
        if (_depthStencil) glDeleteRenderbuffers(1, &_depthStencil);
        CGLSetCurrentContext(NULL);
        CGLDestroyContext(_context);
    }
    free(_scratch);
}

- (void)makeCurrent {
    CGLSetCurrentContext(_context);
}

+ (void)clearCurrent {
    CGLSetCurrentContext(NULL);
}

- (unsigned)framebufferID { return _fbo; }

- (BOOL)resizeFramebufferWidth:(unsigned)width height:(unsigned)height {
    if (width == 0 || height == 0) return NO;
    if (_fbo && width == _framebufferWidth && height == _framebufferHeight) return YES;

    CGLSetCurrentContext(_context);
    if (_fbo) glDeleteFramebuffers(1, &_fbo);
    if (_colorTexture) glDeleteTextures(1, &_colorTexture);
    if (_depthStencil) glDeleteRenderbuffers(1, &_depthStencil);
    _fbo = _colorTexture = _depthStencil = 0;

    glGenTextures(1, &_colorTexture);
    glBindTexture(GL_TEXTURE_2D, _colorTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)width, (GLsizei)height, 0,
                 GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, NULL);
    glBindTexture(GL_TEXTURE_2D, 0);

    glGenFramebuffers(1, &_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _colorTexture, 0);

    if (_depth || _stencil) {
        glGenRenderbuffers(1, &_depthStencil);
        glBindRenderbuffer(GL_RENDERBUFFER, _depthStencil);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, (GLsizei)width, (GLsizei)height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthStencil);
        if (_stencil) {
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _depthStencil);
        }
        glBindRenderbuffer(GL_RENDERBUFFER, 0);
    }

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    _framebufferWidth = width;
    _framebufferHeight = height;
    return status == GL_FRAMEBUFFER_COMPLETE;
}

- (void)readPixelsWidth:(unsigned)width
                 height:(unsigned)height
       bottomLeftOrigin:(BOOL)bottomLeftOrigin
            destination:(uint8_t *)destination {
    if (!_fbo || width == 0 || height == 0) return;
    width = MIN(width, _framebufferWidth);
    height = MIN(height, _framebufferHeight);

    size_t pitch = (size_t)width * 4;
    size_t needed = pitch * height;
    uint8_t *target = destination;
    if (bottomLeftOrigin) {
        if (_scratchSize < needed) {
            free(_scratch);
            _scratch = malloc(needed);
            _scratchSize = needed;
        }
        target = _scratch;
    }

    glBindFramebuffer(GL_READ_FRAMEBUFFER, _fbo);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, target);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);

    if (bottomLeftOrigin) {
        for (unsigned y = 0; y < height; y++) {
            memcpy(destination + (size_t)y * pitch, _scratch + (size_t)(height - 1 - y) * pitch, pitch);
        }
    }
}

+ (nullable void *)procAddress:(const char *)symbol {
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_GLOBAL);
    });
    void *address = handle ? dlsym(handle, symbol) : NULL;
    return address ?: dlsym(RTLD_DEFAULT, symbol);
}

@end
