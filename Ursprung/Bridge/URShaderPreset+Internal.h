// SPDX-License-Identifier: GPL-3.0-or-later
// Shared by URShaderPreset and URShaderChain.

#import "URShaderPreset.h"

#define LIBRA_RUNTIME_METAL
#include "librashader.h"

NS_ASSUME_NONNULL_BEGIN

/// Turns a librashader error into an NSError and frees it.
NSError *URShaderError(libra_error_t error);

/// Stores `result` in `error` as NSError (or frees it) and returns NO when
/// it is an error.
BOOL URShaderCheck(libra_error_t result, NSError **error);

NS_ASSUME_NONNULL_END
