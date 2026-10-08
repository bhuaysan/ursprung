// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — headless Vulkan context (MoltenVK) for libretro cores that render
// with Vulkan (paraLLEl-RDP, Dolphin, Flycast, …). It creates the instance and
// device, negotiating them with the core, implements
// retro_hw_render_interface_vulkan and reads each frame back into system
// memory, like URGLContext does for OpenGL. See docs/VULKAN_PLAN.md.
//
// Everything except the queue lock runs on the emulation thread.

#import <Foundation/Foundation.h>

#import "libretro_vulkan.h"

NS_ASSUME_NONNULL_BEGIN

@interface URVulkanContext : NSObject

/// Whether MoltenVK offers a Vulkan device on this Mac. Probed once.
@property (class, nonatomic, readonly) BOOL isAvailable;

/// Creates the instance and the device. `negotiation` is the core's
/// interface (SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE), or NULL.
- (nullable instancetype)initWithNegotiation:(nullable const struct retro_hw_render_context_negotiation_interface_vulkan *)negotiation
                                       error:(NSError **)error;

/// What GET_HW_RENDER_INTERFACE hands to the core; valid until -destroy.
@property (nonatomic, readonly) const struct retro_hw_render_interface_vulkan *renderInterface;

/// The GPU and how the device was made, for logs.
@property (nonatomic, readonly, copy) NSString *summary;

/// Advances the sync index; call before every retro_run.
- (void)beginFrame;

/// Submits the work the core handed over for this frame (command buffers,
/// semaphores) and, with a `destination`, copies `width`×`height` pixels of
/// the core's image into it as BGRA8 (row pitch = width * 4). Waits for the
/// GPU. Returns NO when nothing could be copied.
- (BOOL)submitFrameWidth:(unsigned)width
                  height:(unsigned)height
             destination:(nullable uint8_t *)destination;

/// Forgets the core's image, e.g. before retro_reset may destroy it.
- (void)forgetImage;

/// Waits until the GPU is idle, with the queue locked.
- (void)waitIdle;

/// Lets the core free its device resources (destroy_device), then destroys
/// the device and the instance. Called by dealloc if not done before.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
