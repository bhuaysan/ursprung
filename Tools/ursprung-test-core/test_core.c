// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — a libretro core for tests. Its state is the number of frames it
// has run; tests switch failures on through the ur_test_core_* functions.
//
// In Vulkan mode it renders with the frontend's Vulkan context: every frame
// it clears its image to a colour that encodes the frame number, like a real
// core would hand over a rendered frame.

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define VK_NO_PROTOTYPES 1
#include "libretro.h"
#include "libretro_vulkan.h"

static retro_environment_t environment;
static retro_video_refresh_t video;
static retro_input_poll_t inputPoll;
static uint32_t frame;
static bool unserializeFails;
static uint32_t pixels[4 * 4];

#pragma mark - Vulkan mode

/// How the core hands its frames to the frontend.
enum {
    URTestVulkanOff = 0,
    /// Submits itself (with lock_queue) and passes a semaphore to set_image.
    URTestVulkanSubmit = 1,
    /// Passes its command buffer with set_command_buffers.
    URTestVulkanCommandBuffers = 2,
};

#define UR_TEST_SYNC_MAX 4

static int vulkanMode;
static bool vulkanActive;
static uint32_t syncIndicesSeen;
static uint32_t destroyDeviceCalls;
static uint32_t contextDestroyCalls;
static uint32_t unloadGameCalls;
static uint32_t deinitCalls;
static const struct retro_hw_render_interface_vulkan *vulkan;
static struct retro_hw_render_callback hwRender;

static struct {
    PFN_vkGetPhysicalDeviceMemoryProperties getMemoryProperties;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties getQueueFamilies;
    PFN_vkGetDeviceQueue getDeviceQueue;
    PFN_vkCreateImage createImage;
    PFN_vkDestroyImage destroyImage;
    PFN_vkGetImageMemoryRequirements getImageMemoryRequirements;
    PFN_vkAllocateMemory allocateMemory;
    PFN_vkFreeMemory freeMemory;
    PFN_vkBindImageMemory bindImageMemory;
    PFN_vkCreateImageView createImageView;
    PFN_vkDestroyImageView destroyImageView;
    PFN_vkCreateCommandPool createCommandPool;
    PFN_vkDestroyCommandPool destroyCommandPool;
    PFN_vkAllocateCommandBuffers allocateCommandBuffers;
    PFN_vkBeginCommandBuffer beginCommandBuffer;
    PFN_vkEndCommandBuffer endCommandBuffer;
    PFN_vkCmdPipelineBarrier cmdPipelineBarrier;
    PFN_vkCmdClearColorImage cmdClearColorImage;
    PFN_vkQueueSubmit queueSubmit;
    PFN_vkCreateSemaphore createSemaphore;
    PFN_vkDestroySemaphore destroySemaphore;
    PFN_vkCreateFence createFence;
    PFN_vkDestroyFence destroyFence;
    PFN_vkWaitForFences waitForFences;
    PFN_vkResetFences resetFences;
    PFN_vkDeviceWaitIdle deviceWaitIdle;
} vk;

/// One per sync index: the core must not touch them before the frontend is done.
static struct {
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    struct retro_vulkan_image retroImage;
    VkCommandBuffer commands;
    VkSemaphore rendered;
    VkFence fence;
    bool submitted;
} slots[UR_TEST_SYNC_MAX];
static uint32_t slotCount;
static VkCommandPool commandPool;

// Test switches for the frontend's side of the contract (libretro_vulkan.h).
/// The image view swaps red and blue.
static bool swizzledView;
/// With command buffers, set_image also passes a semaphore nobody signals:
/// in that mode the frontend must ignore it.
static bool ignoredSemaphore;
/// Every run first refreshes a duplicate frame with its own signal
/// semaphore, then the real frame with another; each must be signalled.
static bool signalsFrames;
static uint32_t signalsSeen;
/// After handing over a frame, waits for its sync index within the same run,
/// as cores do before reusing what the frame used.
static bool waitsAfterFrame;
static uint32_t waitsReturned;
static VkSemaphore neverSignaled;
static VkSemaphore duplicateSignal;
static VkSemaphore frameSignal;
static VkFence checkFence;

RETRO_API void ur_test_core_set_vulkan_mode(int mode) { vulkanMode = mode; }
/// Whether the loaded game renders with Vulkan (the frontend accepted it).
RETRO_API bool ur_test_core_vulkan_active(void) { return vulkanActive; }
/// Bit N is set once get_sync_index returned N.
RETRO_API uint32_t ur_test_core_sync_indices_seen(void) { return syncIndicesSeen; }
RETRO_API uint32_t ur_test_core_destroy_device_calls(void) { return destroyDeviceCalls; }
RETRO_API uint32_t ur_test_core_context_destroy_calls(void) { return contextDestroyCalls; }
RETRO_API uint32_t ur_test_core_unload_game_calls(void) { return unloadGameCalls; }
RETRO_API uint32_t ur_test_core_deinit_calls(void) { return deinitCalls; }
RETRO_API void ur_test_core_set_swizzled_view(bool on) { swizzledView = on; }
RETRO_API void ur_test_core_set_ignored_semaphore(bool on) { ignoredSemaphore = on; }
RETRO_API void ur_test_core_set_signals_frames(bool on) { signalsFrames = on; }
/// How many of the signal semaphores (see signalsFrames) were signalled.
RETRO_API uint32_t ur_test_core_signals_seen(void) { return signalsSeen; }
RETRO_API void ur_test_core_set_waits_after_frame(bool on) { waitsAfterFrame = on; }
/// How often wait_sync_index returned after a frame (see waitsAfterFrame).
RETRO_API uint32_t ur_test_core_waits_returned(void) { return waitsReturned; }

/// The colour frame `n` is cleared to, as the frontend's BGRA8 pixel.
RETRO_API uint32_t ur_test_core_vulkan_pixel(uint32_t n) { return 0xFF000000u | ((n & 0xFF) << 16) | 0x4080u; }

static const VkApplicationInfo *TestApplicationInfo(void) {
    static const VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Ursprung Test Core",
        .apiVersion = VK_API_VERSION_1_1,
    };
    return &app;
}

/// Negotiation v2: makes the device through the frontend's wrapper.
static bool TestCreateDevice2(struct retro_vulkan_context *context, VkInstance instance, VkPhysicalDevice gpu,
                              VkSurfaceKHR surface, PFN_vkGetInstanceProcAddr getInstanceProcAddr,
                              retro_vulkan_create_device_wrapper_t createDevice, void *opaque) {
    (void)surface;
    if (gpu == VK_NULL_HANDLE) return false;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties getFamilies =
        (PFN_vkGetPhysicalDeviceQueueFamilyProperties)getInstanceProcAddr(instance, "vkGetPhysicalDeviceQueueFamilyProperties");
    PFN_vkGetDeviceProcAddr getDeviceProcAddr = (PFN_vkGetDeviceProcAddr)getInstanceProcAddr(instance, "vkGetDeviceProcAddr");
    VkQueueFamilyProperties families[16];
    uint32_t count = 16;
    getFamilies(gpu, &count, families);
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < count && family == UINT32_MAX; i++) {
        if ((families[i].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) == (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) family = i;
    }
    if (family == UINT32_MAX) return false;
    static const float priority = 1.0f;
    VkDeviceQueueCreateInfo queue = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    VkDeviceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue,
    };
    VkDevice device = createDevice(gpu, opaque, &info);
    if (!device) return false;
    PFN_vkGetDeviceQueue getQueue = (PFN_vkGetDeviceQueue)getDeviceProcAddr(device, "vkGetDeviceQueue");
    context->gpu = gpu;
    context->device = device;
    getQueue(device, family, 0, &context->queue);
    context->queue_family_index = family;
    context->presentation_queue = context->queue;
    context->presentation_queue_family_index = family;
    return true;
}

static void TestDestroyDevice(void) { destroyDeviceCalls++; }

static const struct retro_hw_render_context_negotiation_interface_vulkan negotiation = {
    .interface_type = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN,
    .interface_version = 2,
    .get_application_info = TestApplicationInfo,
    .destroy_device = TestDestroyDevice,
    .create_device2 = TestCreateDevice2,
};

static uint32_t TestMemoryType(uint32_t bits, VkMemoryPropertyFlags flags) {
    VkPhysicalDeviceMemoryProperties properties;
    vk.getMemoryProperties(vulkan->gpu, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; i++) {
        if ((bits & (1u << i)) && (properties.memoryTypes[i].propertyFlags & flags) == flags) return i;
    }
    return 0;
}

static void TestDestroyResources(void) {
    if (!vulkan) return;
    VkDevice device = vulkan->device;
    vk.deviceWaitIdle(device);
    for (uint32_t i = 0; i < slotCount; i++) {
        vk.destroyFence(device, slots[i].fence, NULL);
        vk.destroySemaphore(device, slots[i].rendered, NULL);
        vk.destroyImageView(device, slots[i].view, NULL);
        vk.destroyImage(device, slots[i].image, NULL);
        vk.freeMemory(device, slots[i].memory, NULL);
    }
    if (commandPool) vk.destroyCommandPool(device, commandPool, NULL);
    commandPool = VK_NULL_HANDLE;
    vk.destroySemaphore(device, neverSignaled, NULL);
    vk.destroySemaphore(device, duplicateSignal, NULL);
    vk.destroySemaphore(device, frameSignal, NULL);
    vk.destroyFence(device, checkFence, NULL);
    neverSignaled = duplicateSignal = frameSignal = VK_NULL_HANDLE;
    checkFence = VK_NULL_HANDLE;
    memset(slots, 0, sizeof(slots));
    slotCount = 0;
}

static void TestContextReset(void) {
    if (!environment(RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE, (void *)&vulkan) || !vulkan
        || vulkan->interface_type != RETRO_HW_RENDER_INTERFACE_VULKAN) {
        vulkan = NULL;
        return;
    }
    VkInstance instance = vulkan->instance;
    VkDevice device = vulkan->device;
#define UR_INSTANCE(field, name) vk.field = (void *)vulkan->get_instance_proc_addr(instance, name)
#define UR_DEVICE(field, name) vk.field = (void *)vulkan->get_device_proc_addr(device, name)
    UR_INSTANCE(getMemoryProperties, "vkGetPhysicalDeviceMemoryProperties");
    UR_INSTANCE(getQueueFamilies, "vkGetPhysicalDeviceQueueFamilyProperties");
    UR_DEVICE(getDeviceQueue, "vkGetDeviceQueue");
    UR_DEVICE(createImage, "vkCreateImage");
    UR_DEVICE(destroyImage, "vkDestroyImage");
    UR_DEVICE(getImageMemoryRequirements, "vkGetImageMemoryRequirements");
    UR_DEVICE(allocateMemory, "vkAllocateMemory");
    UR_DEVICE(freeMemory, "vkFreeMemory");
    UR_DEVICE(bindImageMemory, "vkBindImageMemory");
    UR_DEVICE(createImageView, "vkCreateImageView");
    UR_DEVICE(destroyImageView, "vkDestroyImageView");
    UR_DEVICE(createCommandPool, "vkCreateCommandPool");
    UR_DEVICE(destroyCommandPool, "vkDestroyCommandPool");
    UR_DEVICE(allocateCommandBuffers, "vkAllocateCommandBuffers");
    UR_DEVICE(beginCommandBuffer, "vkBeginCommandBuffer");
    UR_DEVICE(endCommandBuffer, "vkEndCommandBuffer");
    UR_DEVICE(cmdPipelineBarrier, "vkCmdPipelineBarrier");
    UR_DEVICE(cmdClearColorImage, "vkCmdClearColorImage");
    UR_DEVICE(queueSubmit, "vkQueueSubmit");
    UR_DEVICE(createSemaphore, "vkCreateSemaphore");
    UR_DEVICE(destroySemaphore, "vkDestroySemaphore");
    UR_DEVICE(createFence, "vkCreateFence");
    UR_DEVICE(destroyFence, "vkDestroyFence");
    UR_DEVICE(waitForFences, "vkWaitForFences");
    UR_DEVICE(resetFences, "vkResetFences");
    UR_DEVICE(deviceWaitIdle, "vkDeviceWaitIdle");
#undef UR_INSTANCE
#undef UR_DEVICE

    VkCommandPoolCreateInfo pool = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = vulkan->queue_index,
    };
    vk.createCommandPool(device, &pool, NULL, &commandPool);
    VkSemaphoreCreateInfo semaphoreInfo = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    vk.createSemaphore(device, &semaphoreInfo, NULL, &neverSignaled);
    vk.createSemaphore(device, &semaphoreInfo, NULL, &duplicateSignal);
    vk.createSemaphore(device, &semaphoreInfo, NULL, &frameSignal);
    VkFenceCreateInfo fenceInfo = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    vk.createFence(device, &fenceInfo, NULL, &checkFence);

    uint32_t mask = vulkan->get_sync_index_mask(vulkan->handle);
    slotCount = 0;
    while (slotCount < UR_TEST_SYNC_MAX && (mask & (1u << slotCount))) slotCount++;
    for (uint32_t i = 0; i < slotCount; i++) {
        VkImageCreateInfo image = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT,
            .imageType = VK_IMAGE_TYPE_2D,
            .format = VK_FORMAT_R8G8B8A8_UNORM,
            .extent = {4, 4, 1},
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .tiling = VK_IMAGE_TILING_OPTIMAL,
            .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        };
        vk.createImage(device, &image, NULL, &slots[i].image);
        VkMemoryRequirements requirements;
        vk.getImageMemoryRequirements(device, slots[i].image, &requirements);
        VkMemoryAllocateInfo allocate = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size,
            .memoryTypeIndex = TestMemoryType(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };
        vk.allocateMemory(device, &allocate, NULL, &slots[i].memory);
        vk.bindImageMemory(device, slots[i].image, slots[i].memory, 0);

        VkImageViewCreateInfo view = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = slots[i].image,
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = VK_FORMAT_R8G8B8A8_UNORM,
            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
        };
        if (swizzledView) {
            view.components = (VkComponentMapping){VK_COMPONENT_SWIZZLE_B, VK_COMPONENT_SWIZZLE_G,
                                                   VK_COMPONENT_SWIZZLE_R, VK_COMPONENT_SWIZZLE_A};
        }
        vk.createImageView(device, &view, NULL, &slots[i].view);
        slots[i].retroImage.image_view = slots[i].view;
        slots[i].retroImage.image_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        slots[i].retroImage.create_info = view;

        VkCommandBufferAllocateInfo commands = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = commandPool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        vk.allocateCommandBuffers(device, &commands, &slots[i].commands);
        VkSemaphoreCreateInfo semaphore = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        vk.createSemaphore(device, &semaphore, NULL, &slots[i].rendered);
        VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        vk.createFence(device, &fence, NULL, &slots[i].fence);
    }
}

static void TestContextDestroy(void) {
    contextDestroyCalls++;
    TestDestroyResources();
    vulkan = NULL;
}

/// Whether the frontend signalled `semaphore`: waits for it on the GPU, for
/// at most two seconds.
static bool TestConsumeSignal(VkSemaphore semaphore) {
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &semaphore,
        .pWaitDstStageMask = &stage,
    };
    vulkan->lock_queue(vulkan->handle);
    VkResult result = vk.queueSubmit(vulkan->queue, 1, &submit, checkFence);
    vulkan->unlock_queue(vulkan->handle);
    if (result != VK_SUCCESS) return false;
    if (vk.waitForFences(vulkan->device, 1, &checkFence, VK_TRUE, 2ull * 1000 * 1000 * 1000) != VK_SUCCESS) return false;
    vk.resetFences(vulkan->device, 1, &checkFence);
    return true;
}

/// Clears the image of this sync index to the frame's colour and hands it over.
static void TestRenderVulkanFrame(void) {
    if (!vulkan || slotCount == 0) return;
    if (signalsFrames && video) {
        vulkan->set_signal_semaphore(vulkan->handle, duplicateSignal);
        video(NULL, 4, 4, 0);
        if (TestConsumeSignal(duplicateSignal)) signalsSeen++;
    }
    uint32_t index = vulkan->get_sync_index(vulkan->handle);
    if (index >= slotCount) return;
    syncIndicesSeen |= 1u << index;
    VkDevice device = vulkan->device;
    if (vulkanMode == URTestVulkanSubmit) {
        if (slots[index].submitted) vk.waitForFences(device, 1, &slots[index].fence, VK_TRUE, UINT64_MAX);
        vk.resetFences(device, 1, &slots[index].fence);
    } else {
        // The frontend submits our commands: its sync index says when they ran.
        vulkan->wait_sync_index(vulkan->handle);
    }

    VkCommandBuffer cmd = slots[index].commands;
    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    vk.beginCommandBuffer(cmd, &begin);
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageMemoryBarrier toTransfer = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = slots[index].image,
        .subresourceRange = range,
    };
    vk.cmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL,
                          1, &toTransfer);
    VkClearColorValue color = {.float32 = {(float)(frame & 0xFF) / 255.0f, 64.0f / 255.0f, 128.0f / 255.0f, 1.0f}};
    vk.cmdClearColorImage(cmd, slots[index].image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
    VkImageMemoryBarrier toShader = toTransfer;
    toShader.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    toShader.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    toShader.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    toShader.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vk.cmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL,
                          1, &toShader);
    vk.endCommandBuffer(cmd);

    if (vulkanMode == URTestVulkanSubmit) {
        VkSubmitInfo submit = {
            .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &slots[index].rendered,
        };
        vulkan->lock_queue(vulkan->handle);
        vk.queueSubmit(vulkan->queue, 1, &submit, slots[index].fence);
        vulkan->unlock_queue(vulkan->handle);
        slots[index].submitted = true;
        vulkan->set_image(vulkan->handle, &slots[index].retroImage, 1, &slots[index].rendered, vulkan->queue_index);
    } else {
        vulkan->set_command_buffers(vulkan->handle, 1, &cmd);
        if (ignoredSemaphore) {
            vulkan->set_image(vulkan->handle, &slots[index].retroImage, 1, &neverSignaled, vulkan->queue_index);
        } else {
            vulkan->set_image(vulkan->handle, &slots[index].retroImage, 0, NULL, VK_QUEUE_FAMILY_IGNORED);
        }
    }
    if (signalsFrames) vulkan->set_signal_semaphore(vulkan->handle, frameSignal);
    if (video) video(RETRO_HW_FRAME_BUFFER_VALID, 4, 4, 0);
    if (signalsFrames && TestConsumeSignal(frameSignal)) signalsSeen++;
    if (waitsAfterFrame) {
        vulkan->wait_sync_index(vulkan->handle);
        waitsReturned++;
    }
}

#pragma mark - libretro

RETRO_API void ur_test_core_set_unserialize_fails(bool fails) { unserializeFails = fails; }
RETRO_API uint32_t ur_test_core_frame(void) { return frame; }

RETRO_API unsigned retro_api_version(void) { return RETRO_API_VERSION; }

RETRO_API void retro_get_system_info(struct retro_system_info *info) {
    memset(info, 0, sizeof(*info));
    info->library_name = "Ursprung Test Core";
    info->library_version = "1";
    info->valid_extensions = "bin";
    info->need_fullpath = true;
}

RETRO_API void retro_get_system_av_info(struct retro_system_av_info *info) {
    memset(info, 0, sizeof(*info));
    info->geometry.base_width = info->geometry.max_width = 4;
    info->geometry.base_height = info->geometry.max_height = 4;
    info->geometry.aspect_ratio = 1;
    info->timing.fps = 60;
    info->timing.sample_rate = 48000;
}

RETRO_API void retro_set_environment(retro_environment_t callback) {
    environment = callback;
    enum retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
    callback(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);
}

RETRO_API void retro_set_video_refresh(retro_video_refresh_t callback) { video = callback; }
RETRO_API void retro_set_audio_sample(retro_audio_sample_t callback) { (void)callback; }
RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t callback) { (void)callback; }
RETRO_API void retro_set_input_poll(retro_input_poll_t callback) { inputPoll = callback; }
RETRO_API void retro_set_input_state(retro_input_state_t callback) { (void)callback; }
RETRO_API void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }

RETRO_API void retro_init(void) { frame = 0; unserializeFails = false; }
RETRO_API void retro_deinit(void) { deinitCalls++; }
RETRO_API void retro_reset(void) { frame = 0; }

RETRO_API void retro_run(void) {
    if (inputPoll) inputPoll();
    frame++;
    if (vulkanActive) {
        TestRenderVulkanFrame();
    } else if (video) {
        video(pixels, 4, 4, 4 * sizeof(uint32_t));
    }
}

RETRO_API size_t retro_serialize_size(void) { return sizeof(frame); }

RETRO_API bool retro_serialize(void *data, size_t size) {
    if (size < sizeof(frame)) return false;
    memcpy(data, &frame, sizeof(frame));
    return true;
}

RETRO_API bool retro_unserialize(const void *data, size_t size) {
    if (unserializeFails || size < sizeof(frame)) return false;
    memcpy(&frame, data, sizeof(frame));
    return true;
}

RETRO_API bool retro_load_game(const struct retro_game_info *game) {
    (void)game;
    vulkanActive = false;
    syncIndicesSeen = 0;
    signalsSeen = 0;
    vulkan = NULL;
    if (vulkanMode != URTestVulkanOff) {
        memset(&hwRender, 0, sizeof(hwRender));
        hwRender.context_type = RETRO_HW_CONTEXT_VULKAN;
        hwRender.version_major = VK_API_VERSION_1_1;
        hwRender.context_reset = TestContextReset;
        hwRender.context_destroy = TestContextDestroy;
        vulkanActive = environment(RETRO_ENVIRONMENT_SET_HW_RENDER, &hwRender)
            && environment(RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE, (void *)&negotiation);
    }
    return true;
}

RETRO_API void retro_unload_game(void) {
    unloadGameCalls++;
    vulkanActive = false;
}
RETRO_API void *retro_get_memory_data(unsigned id) { (void)id; return NULL; }
RETRO_API size_t retro_get_memory_size(unsigned id) { (void)id; return 0; }
