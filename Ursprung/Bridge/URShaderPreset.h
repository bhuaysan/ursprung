// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — RetroArch slang shader presets read through librashader
// (ThirdParty/librashader). Parsing reads the preset and its shader files
// but compiles nothing, so it is cheap and safe on any thread.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Errors carry librashader's error number as code and its message as
/// localized description.
extern NSErrorDomain const URShaderErrorDomain NS_SWIFT_NAME(ShaderErrorDomain);

/// A parameter a preset's shaders declare with `#pragma parameter`.
NS_SWIFT_NAME(ShaderParameter)
NS_SWIFT_SENDABLE
@interface URShaderParameter : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *label;
/// The value the preset starts with, including its overrides.
@property (nonatomic, readonly) float initial;
@property (nonatomic, readonly) float minimum;
@property (nonatomic, readonly) float maximum;
@property (nonatomic, readonly) float step;
@end

NS_SWIFT_NAME(ShaderPreset)
@interface URShaderPreset : NSObject

/// The parameters of the `.slangp` preset at `path`, in librashader's order.
+ (nullable NSArray<URShaderParameter *> *)parametersOfPresetAtPath:(NSString *)path error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
