// SPDX-License-Identifier: GPL-3.0-or-later

#import "URShaderPreset+Internal.h"

NSErrorDomain const URShaderErrorDomain = @"Ursprung.Shader";

NSError *URShaderError(libra_error_t error) {
    char *message = NULL;
    libra_error_write(error, &message);
    NSString *description = message ? @(message) : @"Unknown librashader error";
    libra_error_free_string(&message);
    NSInteger code = libra_error_errno(error);
    libra_error_free(&error);
    return [NSError errorWithDomain:URShaderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

BOOL URShaderCheck(libra_error_t result, NSError **error) {
    if (!result) return YES;
    if (error) *error = URShaderError(result);
    else libra_error_free(&result);
    return NO;
}

@implementation URShaderParameter

- (instancetype)initWithParameter:(const libra_preset_param_t *)parameter {
    if ((self = [super init])) {
        _name = @(parameter->name ?: "");
        _label = [@(parameter->description ?: "") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        _initial = parameter->initial;
        _minimum = parameter->minimum;
        _maximum = parameter->maximum;
        _step = parameter->step;
    }
    return self;
}

@end

@implementation URShaderPreset

+ (NSArray<URShaderParameter *> *)parametersOfPresetAtPath:(NSString *)path error:(NSError **)error {
    libra_shader_preset_t preset = NULL;
    libra_preset_opt_t options = {.version = LIBRASHADER_CURRENT_VERSION};
    if (!URShaderCheck(libra_preset_create_with_options(path.fileSystemRepresentation, NULL, &options, &preset), error)) {
        return nil;
    }

    libra_preset_param_list_t list = {0};
    if (!URShaderCheck(libra_preset_get_runtime_params(&preset, &list), error)) {
        libra_preset_free(&preset);
        return nil;
    }
    NSMutableArray<URShaderParameter *> *parameters = [NSMutableArray arrayWithCapacity:(NSUInteger)list.length];
    for (uint64_t i = 0; i < list.length; i++) {
        [parameters addObject:[[URShaderParameter alloc] initWithParameter:&list.parameters[i]]];
    }
    libra_preset_free_runtime_params(list);
    libra_preset_free(&preset);
    return parameters;
}

@end
