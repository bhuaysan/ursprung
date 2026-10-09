// SPDX-License-Identifier: GPL-3.0-or-later

#import "URShaderChain.h"
#import "URShaderPreset+Internal.h"

/// Whether the preset at `path`, or one it references, has a wildcard such
/// as `$CORE$` in it.
static BOOL URPresetUsesWildcards(NSString *path, NSUInteger depth) {
    static NSRegularExpression *wildcard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ wildcard = [NSRegularExpression regularExpressionWithPattern:@"\\$[A-Z_-]+\\$" options:0 error:NULL]; });
    NSString *text = depth < 16 ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (!text) return NO;
    if ([wildcard firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) return YES;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![trimmed hasPrefix:@"#reference"]) continue;
        NSString *reference = [[trimmed substringFromIndex:@"#reference".length]
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\""]];
        reference = [reference stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if (reference.length == 0) continue;
        NSString *referenced = reference.isAbsolutePath ? reference
            : [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:reference];
        if (URPresetUsesWildcards(referenced.stringByStandardizingPath, depth + 1)) return YES;
    }
    return NO;
}

@implementation URShaderChain {
    libra_mtl_filter_chain_t _chain;
}

- (instancetype)initWithPresetAtPath:(NSString *)path
                               queue:(id<MTLCommandQueue>)queue
                            coreName:(NSString *)coreName
                            rotation:(NSInteger)rotation
                               error:(NSError **)error {
    if (!(self = [super init])) return nil;

    // librashader consumes the context and the preset (and nulls them),
    // also on failure. Its free functions panic on null handles.
    libra_preset_ctx_t context = NULL;
    if (!URShaderCheck(libra_preset_ctx_create(&context), error)) return nil;
    libra_preset_ctx_set_runtime(&context, LIBRA_PRESET_CTX_RUNTIME_METAL);
    if (coreName.length > 0) libra_preset_ctx_set_core_name(&context, coreName.UTF8String);
    libra_preset_ctx_set_core_rotation(&context, (uint32_t)(MAX(rotation, 0) % 4));

    libra_shader_preset_t preset = NULL;
    libra_preset_opt_t presetOptions = {
        .version = LIBRASHADER_CURRENT_VERSION,
        .original_aspect_uniforms = true,
        .frametime_uniforms = true,
    };
    BOOL parsed;
    if (URPresetUsesWildcards(path, 0)) {
        // librashader 0.12.0's libra_preset_create_with_options parses without
        // the context (try_parse, not try_parse_with_context), so wildcards
        // never resolve. The older call applies it, without the original
        // aspect and frame time uniforms.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        parsed = URShaderCheck(libra_preset_create_with_context(path.fileSystemRepresentation, &context, &preset), error);
#pragma clang diagnostic pop
    } else {
        parsed = URShaderCheck(libra_preset_create_with_options(path.fileSystemRepresentation, &context, &presetOptions,
                                                                &preset), error);
    }
    if (context) libra_preset_ctx_free(&context);
    if (!parsed) return nil;

    // Read before compiling, which consumes the preset.
    NSArray<URShaderParameter *> *parameters = URShaderPresetParameters(&preset, error);
    if (!parameters) {
        libra_preset_free(&preset);
        return nil;
    }
    _parameters = [parameters copy];

    filter_chain_mtl_opt_t chainOptions = {.version = LIBRASHADER_CURRENT_VERSION};
    BOOL compiled = URShaderCheck(libra_mtl_filter_chain_create(&preset, queue, &chainOptions, &_chain), error);
    if (preset) libra_preset_free(&preset);
    if (!compiled) return nil;

    uint32_t passes = 0;
    libra_mtl_filter_chain_get_active_pass_count(&_chain, &passes);
    _passCount = passes;
    return self;
}

- (void)dealloc {
    if (_chain) libra_mtl_filter_chain_free(&_chain);
}

- (NSInteger)activePassCount {
    uint32_t passes = 0;
    libra_mtl_filter_chain_get_active_pass_count(&_chain, &passes);
    return passes;
}

- (void)setActivePassCount:(NSInteger)activePassCount {
    uint32_t passes = (uint32_t)MIN(MAX(activePassCount, 1), _passCount);
    URShaderCheck(libra_mtl_filter_chain_set_active_pass_count(&_chain, passes), NULL);
}

- (BOOL)renderTexture:(id<MTLTexture>)input
            toTexture:(id<MTLTexture>)output
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
           frameCount:(NSUInteger)frameCount
              options:(URShaderFrameOptions)options
                error:(NSError **)error {
    frame_mtl_opt_t frameOptions = {
        .version = LIBRASHADER_CURRENT_VERSION,
        // Never cleared: librashader 0.12.0 clears the history in a render
        // pass with one attachment per history texture, which is empty (an
        // error, and an assertion under Metal validation) for presets
        // without history. After a jump, history effects blend a few old frames.
        .clear_history = false,
        .frame_direction = options.direction < 0 ? -1 : 1,
        // The renderer rotates the finished picture, so masks and scanlines
        // follow the game's own lines.
        .rotation = 0,
        .total_subframes = 1,
        .current_subframe = 1,
        .aspect_ratio = options.aspectRatio,
        .frames_per_second = options.framesPerSecond,
        .frametime_delta = options.frameTimeDelta,
    };
    libra_viewport_t viewport = {.x = 0, .y = 0, .width = (uint32_t)output.width, .height = (uint32_t)output.height};
    return URShaderCheck(libra_mtl_filter_chain_frame(&_chain, commandBuffer, frameCount, input, output, &viewport, NULL,
                                                      &frameOptions), error);
}

- (NSNumber *)valueForParameter:(NSString *)name {
    float value = 0;
    if (!URShaderCheck(libra_mtl_filter_chain_get_param(&_chain, name.UTF8String, &value), NULL)) return nil;
    return @(value);
}

- (BOOL)setValue:(float)value forParameter:(NSString *)name error:(NSError **)error {
    return URShaderCheck(libra_mtl_filter_chain_set_param(&_chain, name.UTF8String, value), error);
}

@end
