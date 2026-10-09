// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — failures of the GPU context, simulated for tests.

#import "URLibretroCore.h"

NS_ASSUME_NONNULL_BEGIN

@interface URLibretroCore ()

/// Makes the Vulkan context's next wait for a frame return `result` (a
/// VkResult such as VK_TIMEOUT) instead of waiting; several calls queue up.
- (void)simulateVulkanFenceWaitResult:(int32_t)result;

/// Whether a frame that did not finish in time may still run on the GPU.
@property (nonatomic, readonly) BOOL vulkanBusy;

@end

NS_ASSUME_NONNULL_END
