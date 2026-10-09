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

/// A frame the core presented (RETRO_HW_FRAME_BUFFER_VALID): submits the
/// work it handed over (command buffers, semaphores) and, with a
/// `destination`, copies `width`×`height` pixels of its image into it as
/// BGRA8 (row pitch = width * 4). Waits for the GPU. Returns NO when nothing
/// could be copied.
- (BOOL)submitFrameWidth:(unsigned)width
                  height:(unsigned)height
             destination:(nullable uint8_t *)destination;

/// A duplicate frame (video refresh with NULL), or work handed over without
/// any video refresh: runs the core's command buffers and signals its
/// semaphore, but waits for none of the image's semaphores and leaves the
/// image alone. Waits for the GPU.
- (void)submitDuplicateFrame;

/// Whether the context gave up for good: a frame did not finish on the GPU in
/// time, the device was lost or memory ran out. The core's resources may
/// still be in use, so the game must not run on.
@property (nonatomic, readonly, getter=hasFailed) BOOL failed;

/// Whether a frame that did not finish in time may still run on the GPU.
/// Until it is done nothing it uses may be reused or destroyed: no
/// wait_sync_index returns, and the core must not get context_destroy,
/// retro_unload_game or retro_deinit.
@property (nonatomic, readonly, getter=isBusy) BOOL busy;

/// Waits up to `timeout` nanoseconds for that frame. YES once nothing runs
/// any more: it finished, or the device is lost.
- (BOOL)settleWithin:(uint64_t)timeout;

/// Makes the next wait for a frame's fence return `result` (e.g. VK_TIMEOUT,
/// VK_ERROR_DEVICE_LOST) instead of waiting; several calls queue up. Real
/// waits follow once the queue is empty. For tests.
- (void)simulateFenceWaitResult:(VkResult)result;

/// Forgets the core's image, e.g. before retro_reset may destroy it.
- (void)forgetImage;

/// Waits for a frame that did not finish in time (once more, up to the frame
/// timeout), then until the GPU is idle, with the queue locked. NO when that
/// frame still runs: the core's resources must stay.
- (BOOL)waitIdle;

/// Lets the core free its device resources (destroy_device), then destroys
/// the device and the instance. Called by dealloc if not done before.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
