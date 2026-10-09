// SPDX-License-Identifier: GPL-3.0-or-later
//
// The negotiation and the per-frame contract follow RetroArch's Vulkan driver
// (gfx/common/vulkan_common.c, gfx/drivers/vulkan.c), the reference
// implementation of libretro_vulkan.h. Unlike RetroArch, Ursprung has no
// swapchain: each frame is copied into a host-visible buffer and waited for.
// Cores still get a surface (of a layer nobody sees), as in RetroArch: Dolphin
// emulates a swapchain on top of it and presents nothing without one.

#import "URVulkanContext.h"

#import <QuartzCore/CAMetalLayer.h>
#include <vulkan/vulkan_metal.h>

#import "URPixelConversion.h"

#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>

static NSString *const URVulkanErrorDomain = @"Ursprung.Vulkan";

/// Sync indices the core sees; frames are waited for, so two are plenty.
static const uint32_t URVulkanSyncIndexCount = 2;
/// How long a frame may take on the GPU before Ursprung gives up on the
/// context (and the game stops).
static const uint64_t URVulkanFenceTimeout = 10ull * 1000 * 1000 * 1000;
/// Room for the core's command buffers; set_command_buffers grows it.
static const uint32_t URVulkanInitialCommandBufferCapacity = 4;
/// Simulated fence results a test can queue up.
#define UR_VULKAN_SIMULATED_WAITS 8

static os_log_t URVulkanLogHandle(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("io.github.bhuaysan.Ursprung", "vulkan"); });
    return log;
}

/// Logs to the unified log, and to stderr when URSPRUNG_VULKAN_LOG is set
/// (ursprung-smoke, debugging a core).
static void URVulkanLog(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void URVulkanLog(const char *format, ...) {
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    os_log(URVulkanLogHandle(), "%{public}s", message);
    if (getenv("URSPRUNG_VULKAN_LOG")) fprintf(stderr, "[vulkan] %s\n", message);
}

static NSError *URVulkanError(NSString *message, VkResult result) {
    NSString *description = result == VK_SUCCESS ? message : [NSString stringWithFormat:@"%@ (VkResult %d)", message, result];
    return [NSError errorWithDomain:URVulkanErrorDomain code:result userInfo:@{NSLocalizedDescriptionKey: description}];
}

#pragma mark - Extensions

static BOOL URExtensionListContains(const char *const *names, uint32_t count, const char *name) {
    for (uint32_t i = 0; i < count; i++) {
        if (names[i] && strcmp(names[i], name) == 0) return YES;
    }
    return NO;
}

static BOOL URInstanceSupports(const char *name) {
    uint32_t count = 0;
    if (vkEnumerateInstanceExtensionProperties(NULL, &count, NULL) != VK_SUCCESS || count == 0) return NO;
    VkExtensionProperties *properties = calloc(count, sizeof(*properties));
    BOOL found = NO;
    if (properties && vkEnumerateInstanceExtensionProperties(NULL, &count, properties) == VK_SUCCESS) {
        for (uint32_t i = 0; i < count && !found; i++) found = strcmp(properties[i].extensionName, name) == 0;
    }
    free(properties);
    return found;
}

static BOOL URDeviceSupports(VkPhysicalDevice gpu, const char *name) {
    uint32_t count = 0;
    if (vkEnumerateDeviceExtensionProperties(gpu, NULL, &count, NULL) != VK_SUCCESS || count == 0) return NO;
    VkExtensionProperties *properties = calloc(count, sizeof(*properties));
    BOOL found = NO;
    if (properties && vkEnumerateDeviceExtensionProperties(gpu, NULL, &count, properties) == VK_SUCCESS) {
        for (uint32_t i = 0; i < count && !found; i++) found = strcmp(properties[i].extensionName, name) == 0;
    }
    free(properties);
    return found;
}

static void URLogExtensions(const char *what, const char *const *names, uint32_t count) {
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (uint32_t i = 0; i < count; i++) {
        if (names[i]) [list addObject:@(names[i])];
    }
    URVulkanLog("%s extensions: %s", what, list.count ? [list componentsJoinedByString:@", "].UTF8String : "none");
}

#pragma mark - Instance and device creation

/// vkCreateInstance for the frontend and for cores (negotiation v2). Adds
/// the surface extensions and, like RetroArch on Apple, portability
/// enumeration where MoltenVK reports it.
static VkInstance URCreateInstance(void *opaque, const VkInstanceCreateInfo *createInfo) {
    (void)opaque;
    VkInstanceCreateInfo info = *createInfo;
    const char **extensions = calloc(info.enabledExtensionCount + 3, sizeof(char *));
    if (!extensions) return VK_NULL_HANDLE;
    if (info.enabledExtensionCount) {
        memcpy(extensions, info.ppEnabledExtensionNames, info.enabledExtensionCount * sizeof(char *));
    }
    const char *added[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME,
                           VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
    for (size_t i = 0; i < sizeof(added) / sizeof(added[0]); i++) {
        if (URExtensionListContains(extensions, info.enabledExtensionCount, added[i]) || !URInstanceSupports(added[i])) continue;
        extensions[info.enabledExtensionCount++] = added[i];
        if (strcmp(added[i], VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) == 0) {
            info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
        }
    }
    info.ppEnabledExtensionNames = extensions;
    URLogExtensions("Instance", extensions, info.enabledExtensionCount);

    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = vkCreateInstance(&info, NULL, &instance);
    free(extensions);
    if (result != VK_SUCCESS) {
        URVulkanLog("vkCreateInstance failed (%d)", result);
        return VK_NULL_HANDLE;
    }
    return instance;
}

/// vkCreateDevice for the frontend and for cores, with the swapchain extension
/// RetroArch always asks for and VK_KHR_portability_subset, which the
/// specification requires where the device has it.
static VKAPI_ATTR VkResult VKAPI_CALL URCreateDevice(VkPhysicalDevice gpu, const VkDeviceCreateInfo *createInfo,
                                                     const VkAllocationCallbacks *allocator, VkDevice *device) {
    VkDeviceCreateInfo info = *createInfo;
    const char **extensions = calloc(info.enabledExtensionCount + 2, sizeof(char *));
    if (!extensions) return VK_ERROR_OUT_OF_HOST_MEMORY;
    if (info.enabledExtensionCount) {
        memcpy(extensions, info.ppEnabledExtensionNames, info.enabledExtensionCount * sizeof(char *));
    }
    const char *added[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME, "VK_KHR_portability_subset"};
    for (size_t i = 0; i < sizeof(added) / sizeof(added[0]); i++) {
        if (URExtensionListContains(extensions, info.enabledExtensionCount, added[i]) || !URDeviceSupports(gpu, added[i])) continue;
        extensions[info.enabledExtensionCount++] = added[i];
    }
    info.ppEnabledExtensionNames = extensions;
    URLogExtensions("Device", extensions, info.enabledExtensionCount);

    VkResult result = vkCreateDevice(gpu, &info, allocator, device);
    free(extensions);
    if (result != VK_SUCCESS) URVulkanLog("vkCreateDevice failed (%d)", result);
    return result;
}

/// Negotiation v2: the core creates the device through this wrapper.
static VkDevice URCreateDeviceWrapper(VkPhysicalDevice gpu, void *opaque, const VkDeviceCreateInfo *createInfo) {
    (void)opaque;
    VkDevice device = VK_NULL_HANDLE;
    return URCreateDevice(gpu, createInfo, NULL, &device) == VK_SUCCESS ? device : VK_NULL_HANDLE;
}

/// What cores get as vkGetInstanceProcAddr. Cores that create the device
/// themselves (negotiation v1) call vkCreateDevice through it, so it goes
/// through URCreateDevice as well.
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL URGetInstanceProcAddr(VkInstance instance, const char *name) {
    if (name && strcmp(name, "vkCreateDevice") == 0) return (PFN_vkVoidFunction)URCreateDevice;
    return vkGetInstanceProcAddr(instance, name);
}

static VkApplicationInfo URDefaultApplicationInfo(void) {
    return (VkApplicationInfo){
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Ursprung",
        .pEngineName = "Ursprung",
        .apiVersion = VK_API_VERSION_1_1,
    };
}

/// The first GPU, preferring a real one over a CPU implementation.
static VkPhysicalDevice URChooseGPU(VkInstance instance) {
    uint32_t count = 0;
    if (vkEnumeratePhysicalDevices(instance, &count, NULL) != VK_SUCCESS || count == 0) return VK_NULL_HANDLE;
    VkPhysicalDevice *gpus = calloc(count, sizeof(*gpus));
    if (!gpus) return VK_NULL_HANDLE;
    VkPhysicalDevice chosen = VK_NULL_HANDLE;
    if (vkEnumeratePhysicalDevices(instance, &count, gpus) == VK_SUCCESS) {
        for (uint32_t i = 0; i < count && !chosen; i++) {
            VkPhysicalDeviceProperties properties;
            vkGetPhysicalDeviceProperties(gpus[i], &properties);
            if (properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
                || properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                chosen = gpus[i];
            }
        }
        if (!chosen) chosen = gpus[0];
    }
    free(gpus);
    return chosen;
}

static URPixelLayout URPixelLayoutForFormat(VkFormat format) {
    switch (format) {
        case VK_FORMAT_B8G8R8A8_UNORM:
        case VK_FORMAT_B8G8R8A8_SRGB:
            return URPixelLayoutB8G8R8A8;
        case VK_FORMAT_R8G8B8A8_UNORM:
        case VK_FORMAT_R8G8B8A8_SRGB:
        case VK_FORMAT_A8B8G8R8_UNORM_PACK32:
        case VK_FORMAT_A8B8G8R8_SRGB_PACK32:
            return URPixelLayoutR8G8B8A8;
        case VK_FORMAT_A2B10G10R10_UNORM_PACK32:
            return URPixelLayoutA2B10G10R10;
        case VK_FORMAT_A2R10G10B10_UNORM_PACK32:
            return URPixelLayoutA2R10G10B10;
        case VK_FORMAT_R16G16B16A16_SFLOAT:
            return URPixelLayoutR16G16B16A16Float;
        case VK_FORMAT_R5G6B5_UNORM_PACK16:
            return URPixelLayoutR5G6B5;
        case VK_FORMAT_A1R5G5B5_UNORM_PACK16:
            return URPixelLayoutA1R5G5B5;
        case VK_FORMAT_R5G5B5A1_UNORM_PACK16:
            return URPixelLayoutR5G5B5A1;
        default:
            return URPixelLayoutUnsupported;
    }
}

#pragma mark - Context

// retro_hw_render_interface_vulkan, implemented at the end of this file.
static void URVulkanSetImage(void *handle, const struct retro_vulkan_image *image, uint32_t semaphoreCount,
                             const VkSemaphore *semaphores, uint32_t sourceQueueFamily);
static uint32_t URVulkanGetSyncIndex(void *handle);
static uint32_t URVulkanGetSyncIndexMask(void *handle);
static void URVulkanSetCommandBuffers(void *handle, uint32_t count, const VkCommandBuffer *buffers);
static void URVulkanWaitSyncIndex(void *handle);
static void URVulkanLockQueue(void *handle);
static void URVulkanUnlockQueue(void *handle);
static void URVulkanSetSignalSemaphore(void *handle, VkSemaphore semaphore);

@implementation URVulkanContext {
@public
    VkInstance _instance;
    CAMetalLayer *_layer;
    VkSurfaceKHR _surface;
    VkPhysicalDevice _gpu;
    VkDevice _device;
    VkQueue _queue;
    uint32_t _queueFamily;
    retro_vulkan_destroy_device_t _destroyDevice;
    pthread_mutex_t _queueLock;
    struct retro_hw_render_interface_vulkan _interface;
    uint32_t _syncIndex;

    // Handed over by the core for the next frame (set_image & co).
    VkImage _image;
    VkImageLayout _imageLayout;
    VkFormat _imageFormat;
    URComponentMapping _imageMapping;
    uint32_t _imageMipLevel;
    uint32_t _imageArrayLayer;
    uint32_t _sourceQueueFamily;
    VkSemaphore *_waitSemaphores;
    VkPipelineStageFlags *_waitStages;
    uint32_t _waitSemaphoreCount;
    uint32_t _waitSemaphoreCapacity;
    // The core's command buffers, with room for the readback's after them.
    VkCommandBuffer *_coreCommandBuffers;
    uint32_t _coreCommandBufferCount;
    uint32_t _coreCommandBufferCapacity;
    VkSemaphore _signalSemaphore;

    // See -failed and -busy. After a timeout the last frame may still run on
    // the GPU: nothing it uses may be reused or destroyed until its fence
    // signals.
    BOOL _failed;
    BOOL _fenceUnfinished;
    VkResult _simulatedWaitResults[UR_VULKAN_SIMULATED_WAITS];
    uint32_t _simulatedWaitCount;

    // Readback
    VkCommandPool _commandPool;
    VkCommandBuffer _commandBuffer;
    VkFence _fence;
    VkBuffer _readback;
    VkDeviceMemory _readbackMemory;
    VkDeviceSize _readbackSize;
    void *_readbackPixels;
    VkFormat _reportedFormat;
    VkFormat _loggedFormat;
    // Cost of the readback, logged when the context goes.
    uint64_t _readbackFrames;
    uint64_t _readbackWaitTicks;
    uint64_t _readbackConvertTicks;
}

+ (void)initialize {
    if (self != [URVulkanContext class]) return;
    // MoltenVK logs every instance and device at info level; keep warnings.
    // MVK_CONFIG_* set in the environment still win.
    setenv("MVK_CONFIG_LOG_LEVEL", "2", 0);
}

+ (BOOL)isAvailable {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VkApplicationInfo app = URDefaultApplicationInfo();
        VkInstanceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
        VkInstance instance = URCreateInstance(NULL, &info);
        if (instance) {
            available = URChooseGPU(instance) != VK_NULL_HANDLE;
            vkDestroyInstance(instance, NULL);
        }
        if (!available) URVulkanLog("No Vulkan device: cores fall back to OpenGL or software.");
    });
    return available;
}

- (nullable instancetype)initWithNegotiation:(nullable const struct retro_hw_render_context_negotiation_interface_vulkan *)negotiation
                                       error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    pthread_mutex_init(&_queueLock, NULL);
    _queueFamily = VK_QUEUE_FAMILY_IGNORED;
    _sourceQueueFamily = VK_QUEUE_FAMILY_IGNORED;

    if (negotiation && (negotiation->interface_type != RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN
                        || negotiation->interface_version == 0)) {
        URVulkanLog("Ignoring a negotiation interface of another API or version 0.");
        negotiation = NULL;
    }
    unsigned version = negotiation ? negotiation->interface_version : 0;
    NSString *path = @"default device";

    // Instance
    VkApplicationInfo app = URDefaultApplicationInfo();
    if (negotiation && negotiation->get_application_info) {
        const VkApplicationInfo *coreApp = negotiation->get_application_info();
        if (coreApp) app = *coreApp;
    }
    if (app.apiVersion < VK_API_VERSION_1_1) app.apiVersion = VK_API_VERSION_1_1;
    if (version >= 2 && negotiation->create_instance) {
        _instance = negotiation->create_instance(URGetInstanceProcAddr, &app, URCreateInstance, (__bridge void *)self);
    } else {
        VkInstanceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
        _instance = URCreateInstance((__bridge void *)self, &info);
    }
    if (!_instance) {
        if (error) *error = URVulkanError(@"Could not create a Vulkan instance.", VK_SUCCESS);
        return nil;
    }
    _gpu = URChooseGPU(_instance);
    if (!_gpu) {
        if (error) *error = URVulkanError(@"This Mac offers no Vulkan device.", VK_SUCCESS);
        [self destroy];
        return nil;
    }
    [self createSurface];

    // Device: the core's choice first, as in RetroArch.
    if (negotiation && (negotiation->create_device || (version >= 2 && negotiation->create_device2))) {
        struct retro_vulkan_context context = {0};
        bool created = false;
        if (version >= 2 && negotiation->create_device2) {
            path = @"negotiation v2 (create_device2)";
            created = negotiation->create_device2(&context, _instance, _gpu, _surface, URGetInstanceProcAddr,
                                                  URCreateDeviceWrapper, (__bridge void *)self);
            if (!created) {
                URVulkanLog("create_device2 refused the GPU; letting the core choose.");
                created = negotiation->create_device2(&context, _instance, VK_NULL_HANDLE, _surface,
                                                      URGetInstanceProcAddr, URCreateDeviceWrapper, (__bridge void *)self);
            }
        } else if (negotiation->create_device) {
            path = @"negotiation v1 (create_device)";
            // What RetroArch requires; URCreateDevice adds it anyway.
            static const char *extensions[1] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
            VkPhysicalDeviceFeatures features = {0};
            created = negotiation->create_device(&context, _instance, _gpu, _surface, URGetInstanceProcAddr,
                                                 extensions, 1, NULL, 0, &features);
        }
        if (created && context.device) {
            _destroyDevice = negotiation->destroy_device;
            _device = context.device;
            _gpu = context.gpu ?: _gpu;
            _queue = context.queue;
            _queueFamily = context.queue_family_index;
        } else {
            URVulkanLog("The core could not create a device; using the default device.");
            path = [path stringByAppendingString:@" failed, default device"];
        }
    }
    if (!_device && ![self createDefaultDevice:error]) {
        [self destroy];
        return nil;
    }
    if (!_queue) vkGetDeviceQueue(_device, _queueFamily, 0, &_queue);
    if (![self createReadbackResources:error]) {
        [self destroy];
        return nil;
    }

    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(_gpu, &properties);
    _summary = [NSString stringWithFormat:@"%s, Vulkan %u.%u, %@", properties.deviceName,
                VK_API_VERSION_MAJOR(properties.apiVersion), VK_API_VERSION_MINOR(properties.apiVersion), path];
    URVulkanLog("Context: %s", _summary.UTF8String);
    [self fillInterface];
    return self;
}

- (void)dealloc {
    [self destroy];
    free(_waitSemaphores);
    free(_waitStages);
    free(_coreCommandBuffers);
    pthread_mutex_destroy(&_queueLock);
}

/// A surface for cores that expect one; nothing is ever presented on it.
- (void)createSurface {
    PFN_vkCreateMetalSurfaceEXT create = (PFN_vkCreateMetalSurfaceEXT)vkGetInstanceProcAddr(_instance, "vkCreateMetalSurfaceEXT");
    if (!create) return;
    _layer = [CAMetalLayer layer];
    _layer.drawableSize = CGSizeMake(640, 480);
    VkMetalSurfaceCreateInfoEXT info = {.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT, .pLayer = _layer};
    if (create(_instance, &info, NULL, &_surface) != VK_SUCCESS) {
        URVulkanLog("Could not create a Metal surface; cores get none.");
        _surface = VK_NULL_HANDLE;
        _layer = nil;
    }
}

- (BOOL)createDefaultDevice:(NSError **)error {
    uint32_t count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(_gpu, &count, NULL);
    VkQueueFamilyProperties *families = calloc(count ?: 1, sizeof(*families));
    vkGetPhysicalDeviceQueueFamilyProperties(_gpu, &count, families);
    const VkQueueFlags required = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
    for (uint32_t i = 0; i < count; i++) {
        if ((families[i].queueFlags & required) == required) {
            _queueFamily = i;
            break;
        }
    }
    free(families);
    if (_queueFamily == VK_QUEUE_FAMILY_IGNORED) {
        if (error) *error = URVulkanError(@"The Vulkan device has no graphics queue.", VK_SUCCESS);
        return NO;
    }
    static const float priority = 1.0f;
    VkDeviceQueueCreateInfo queue = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = _queueFamily,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    VkPhysicalDeviceFeatures features = {0};
    VkDeviceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue,
        .pEnabledFeatures = &features,
    };
    VkResult result = URCreateDevice(_gpu, &info, NULL, &_device);
    if (result != VK_SUCCESS) {
        _device = VK_NULL_HANDLE;
        if (error) *error = URVulkanError(@"Could not create a Vulkan device.", result);
        return NO;
    }
    return YES;
}

- (BOOL)createReadbackResources:(NSError **)error {
    VkCommandPoolCreateInfo pool = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = _queueFamily,
    };
    VkResult result = vkCreateCommandPool(_device, &pool, NULL, &_commandPool);
    if (result == VK_SUCCESS) {
        VkCommandBufferAllocateInfo allocate = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = _commandPool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        result = vkAllocateCommandBuffers(_device, &allocate, &_commandBuffer);
    }
    if (result == VK_SUCCESS) {
        VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        result = vkCreateFence(_device, &fence, NULL, &_fence);
    }
    if (result == VK_SUCCESS) {
        _coreCommandBuffers = calloc(URVulkanInitialCommandBufferCapacity, sizeof(VkCommandBuffer));
        _coreCommandBufferCapacity = _coreCommandBuffers ? URVulkanInitialCommandBufferCapacity : 0;
        if (!_coreCommandBuffers) result = VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    if (result != VK_SUCCESS) {
        if (error) *error = URVulkanError(@"Could not prepare the Vulkan frame readback.", result);
        return NO;
    }
    return YES;
}

- (void)fillInterface {
    _interface = (struct retro_hw_render_interface_vulkan){
        .interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN,
        .interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION,
        .handle = (__bridge void *)self,
        .instance = _instance,
        .gpu = _gpu,
        .device = _device,
        .get_device_proc_addr = vkGetDeviceProcAddr,
        .get_instance_proc_addr = URGetInstanceProcAddr,
        .queue = _queue,
        .queue_index = _queueFamily,
    };
    _interface.set_image = URVulkanSetImage;
    _interface.get_sync_index = URVulkanGetSyncIndex;
    _interface.get_sync_index_mask = URVulkanGetSyncIndexMask;
    _interface.set_command_buffers = URVulkanSetCommandBuffers;
    _interface.wait_sync_index = URVulkanWaitSyncIndex;
    _interface.lock_queue = URVulkanLockQueue;
    _interface.unlock_queue = URVulkanUnlockQueue;
    _interface.set_signal_semaphore = URVulkanSetSignalSemaphore;
}

- (const struct retro_hw_render_interface_vulkan *)renderInterface { return &_interface; }

#pragma mark - Frames

- (BOOL)hasFailed { return _failed; }

/// Gives up on the context for good: the core's frames may still be in use on
/// the GPU, or the device is gone, so nothing may run on.
- (void)failWithMessage:(const char *)message result:(VkResult)result {
    if (!_failed) URVulkanLog("%s (VkResult %d); the game stops.", message, result);
    _failed = YES;
}

- (void)beginFrame {
    _syncIndex = (_syncIndex + 1) % URVulkanSyncIndexCount;
}

- (void)forgetImage {
    _image = VK_NULL_HANDLE;
    _waitSemaphoreCount = 0;
    _coreCommandBufferCount = 0;
    _signalSemaphore = VK_NULL_HANDLE;
}

- (void)simulateFenceWaitResult:(VkResult)result {
    if (_simulatedWaitCount < UR_VULKAN_SIMULATED_WAITS) _simulatedWaitResults[_simulatedWaitCount++] = result;
}

/// Waits for the frame's fence, or returns the next simulated result.
- (VkResult)waitForFenceWithin:(uint64_t)timeout {
    if (_simulatedWaitCount > 0) {
        VkResult result = _simulatedWaitResults[0];
        _simulatedWaitCount--;
        memmove(_simulatedWaitResults, _simulatedWaitResults + 1, _simulatedWaitCount * sizeof(VkResult));
        return result;
    }
    return vkWaitForFences(_device, 1, &_fence, VK_TRUE, timeout);
}

/// Grows the readback buffer to `size` bytes.
- (BOOL)ensureReadbackSize:(VkDeviceSize)size {
    if (_readback && _readbackSize >= size) return YES;
    if (_readback) {
        vkUnmapMemory(_device, _readbackMemory);
        vkDestroyBuffer(_device, _readback, NULL);
        vkFreeMemory(_device, _readbackMemory, NULL);
        _readback = VK_NULL_HANDLE;
        _readbackMemory = VK_NULL_HANDLE;
        _readbackPixels = NULL;
        _readbackSize = 0;
    }
    VkBufferCreateInfo buffer = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    if (vkCreateBuffer(_device, &buffer, NULL, &_readback) != VK_SUCCESS) {
        _readback = VK_NULL_HANDLE;
        return NO;
    }
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(_device, _readback, &requirements);
    VkPhysicalDeviceMemoryProperties memory;
    vkGetPhysicalDeviceMemoryProperties(_gpu, &memory);
    const VkMemoryPropertyFlags needed = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uint32_t type = UINT32_MAX;
    for (uint32_t i = 0; i < memory.memoryTypeCount; i++) {
        VkMemoryPropertyFlags flags = memory.memoryTypes[i].propertyFlags;
        if (!(requirements.memoryTypeBits & (1u << i)) || (flags & needed) != needed) continue;
        // Cached memory is much faster to read on the CPU.
        if (type == UINT32_MAX || (flags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT)) type = i;
        if (flags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT) break;
    }
    VkMemoryAllocateInfo allocate = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = type,
    };
    if (type == UINT32_MAX || vkAllocateMemory(_device, &allocate, NULL, &_readbackMemory) != VK_SUCCESS
        || vkBindBufferMemory(_device, _readback, _readbackMemory, 0) != VK_SUCCESS
        || vkMapMemory(_device, _readbackMemory, 0, VK_WHOLE_SIZE, 0, &_readbackPixels) != VK_SUCCESS) {
        if (_readbackMemory) vkFreeMemory(_device, _readbackMemory, NULL);
        vkDestroyBuffer(_device, _readback, NULL);
        _readback = VK_NULL_HANDLE;
        _readbackMemory = VK_NULL_HANDLE;
        _readbackPixels = NULL;
        return NO;
    }
    _readbackSize = size;
    return YES;
}

/// Records what the frame does with the core's image: taking it over from
/// its queue family (`transfer`), copying it into the readback buffer
/// (`copy`) and giving it back.
- (VkResult)recordFrameCopy:(BOOL)copy width:(unsigned)width height:(unsigned)height transferOwnership:(BOOL)transfer {
    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    VkResult result = vkBeginCommandBuffer(_commandBuffer, &begin);
    if (result != VK_SUCCESS) return result;

    // Ownership moves in the layout the core handed the image over in, on
    // both sides, matching the core's own release and acquire (as in
    // RetroArch); the copy's layout changes stay within this queue family.
    VkImageMemoryBarrier acquire = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0,
        .dstAccessMask = copy ? VK_ACCESS_TRANSFER_READ_BIT : 0,
        .oldLayout = _imageLayout,
        .newLayout = _imageLayout,
        .srcQueueFamilyIndex = _sourceQueueFamily,
        .dstQueueFamilyIndex = _queueFamily,
        .image = _image,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS, 0, VK_REMAINING_ARRAY_LAYERS},
    };
    if (transfer) {
        vkCmdPipelineBarrier(_commandBuffer, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0,
                             0, NULL, 0, NULL, 1, &acquire);
    }

    if (copy) {
        // A GENERAL image may not be transitioned (the core may read it meanwhile).
        VkImageLayout copyLayout = _imageLayout == VK_IMAGE_LAYOUT_GENERAL ? VK_IMAGE_LAYOUT_GENERAL
                                                                           : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        VkImageMemoryBarrier toCopy = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = _imageLayout,
            .newLayout = copyLayout,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = _image,
            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, _imageMipLevel, 1, _imageArrayLayer, 1},
        };
        vkCmdPipelineBarrier(_commandBuffer, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                             0, NULL, 0, NULL, 1, &toCopy);

        VkBufferImageCopy region = {
            .imageSubresource = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = _imageMipLevel,
                .baseArrayLayer = _imageArrayLayer,
                .layerCount = 1,
            },
            .imageExtent = {width, height, 1},
        };
        vkCmdCopyImageToBuffer(_commandBuffer, _image, copyLayout, _readback, 1, &region);

        // Back to the layout the core left it in.
        VkImageMemoryBarrier back = toCopy;
        back.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        back.dstAccessMask = 0;
        back.oldLayout = copyLayout;
        back.newLayout = _imageLayout;
        VkBufferMemoryBarrier host = {
            .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .buffer = _readback,
            .size = VK_WHOLE_SIZE,
        };
        vkCmdPipelineBarrier(_commandBuffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT, 0,
                             0, NULL, 1, &host, 1, &back);
    }

    if (transfer) {
        VkImageMemoryBarrier release = acquire;
        release.dstAccessMask = 0;
        release.srcQueueFamilyIndex = _queueFamily;
        release.dstQueueFamilyIndex = _sourceQueueFamily;
        vkCmdPipelineBarrier(_commandBuffer, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0,
                             0, NULL, 0, NULL, 1, &release);
    }
    return vkEndCommandBuffer(_commandBuffer);
}

/// Submits the core's command buffers (first), the frame's own commands and
/// `waitCount` of the image's semaphores, signals the core's semaphore and
/// waits for the GPU. NO when nothing ran or the context failed.
- (BOOL)submitWaitingFor:(uint32_t)waitCount
                    copy:(BOOL)copy
                   width:(unsigned)width
                  height:(unsigned)height
       transferOwnership:(BOOL)transfer {
    BOOL records = copy || transfer;
    uint32_t bufferCount = _coreCommandBufferCount;
    if (!records && bufferCount == 0 && waitCount == 0 && !_signalSemaphore) return NO;
    // Command buffers and the signal semaphore are used once.
    _coreCommandBufferCount = 0;
    VkSemaphore signal = _signalSemaphore;
    _signalSemaphore = VK_NULL_HANDLE;

    VkResult result = VK_SUCCESS;
    if (records) {
        result = [self recordFrameCopy:copy width:width height:height transferOwnership:transfer];
        // set_command_buffers leaves room for this one.
        _coreCommandBuffers[bufferCount++] = _commandBuffer;
    }
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = waitCount,
        .pWaitSemaphores = _waitSemaphores,
        .pWaitDstStageMask = _waitStages,
        .commandBufferCount = bufferCount,
        .pCommandBuffers = _coreCommandBuffers,
        .signalSemaphoreCount = signal ? 1 : 0,
        .pSignalSemaphores = &signal,
    };
    if (result == VK_SUCCESS) result = vkResetFences(_device, 1, &_fence);
    if (result == VK_SUCCESS) {
        pthread_mutex_lock(&_queueLock);
        result = vkQueueSubmit(_queue, 1, &submit, _fence);
        pthread_mutex_unlock(&_queueLock);
    }
    if (result != VK_SUCCESS) {
        [self failWithMessage:"Could not submit a frame" result:result];
        return NO;
    }

    // The fence, the command buffer, the readback buffer and the core's image
    // are all reused next frame: a frame that does not finish in time ends the
    // context rather than running on beside it.
    result = [self waitForFenceWithin:URVulkanFenceTimeout];
    if (result != VK_SUCCESS) {
        // A lost device runs nothing any more; other errors leave it open.
        _fenceUnfinished = result != VK_ERROR_DEVICE_LOST;
        [self failWithMessage:result == VK_TIMEOUT ? "The GPU did not finish a frame in time" : "The GPU failed a frame"
                       result:result];
        return NO;
    }
    return YES;
}

- (BOOL)submitFrameWidth:(unsigned)width height:(unsigned)height destination:(nullable uint8_t *)destination {
    if (!_device || _failed) return NO;
    URPixelLayout layout = URPixelLayoutForFormat(_imageFormat);
    BOOL copy = destination && _image && width > 0 && height > 0;
    if (copy && _imageFormat != _loggedFormat) {
        URVulkanLog("Frames: VkFormat %d, layout %d, %ux%u", _imageFormat, _imageLayout, width, height);
        _loggedFormat = _imageFormat;
    }
    if (copy && layout == URPixelLayoutUnsupported) {
        if (_reportedFormat != _imageFormat) {
            URVulkanLog("The core renders in VkFormat %d, which Ursprung cannot show.", _imageFormat);
            _reportedFormat = _imageFormat;
        }
        copy = NO;
    }
    size_t bytesPerPixel = URPixelLayoutBytesPerPixel(layout);
    if (copy && ![self ensureReadbackSize:(VkDeviceSize)width * height * bytesPerPixel]) {
        URVulkanLog("Could not allocate %ux%u readback memory.", width, height);
        copy = NO;
    }

    // The image's semaphores count only without command buffers: with them
    // the core synchronises through barriers and they are ignored
    // (libretro_vulkan.h, set_image). Either way they are used up. Like
    // RetroArch, the image changes queue family only when they are waited for.
    uint32_t waitCount = _coreCommandBufferCount == 0 ? _waitSemaphoreCount : 0;
    _waitSemaphoreCount = 0;
    BOOL transfer = waitCount > 0 && _image && _sourceQueueFamily != VK_QUEUE_FAMILY_IGNORED
        && _sourceQueueFamily != _queueFamily;

    uint64_t start = mach_absolute_time();
    if (![self submitWaitingFor:waitCount copy:copy width:width height:height transferOwnership:transfer] || !copy) {
        return NO;
    }
    uint64_t waited = mach_absolute_time();
    const URComponentMapping *mapping = &_imageMapping;
    BOOL converted = URConvertPixelsToBGRA8(layout, _readbackPixels, (size_t)width * bytesPerPixel, mapping,
                                            destination, width, height);
    _readbackFrames++;
    _readbackWaitTicks += waited - start;
    _readbackConvertTicks += mach_absolute_time() - waited;
    return converted;
}

- (void)submitDuplicateFrame {
    if (!_device || _failed) return;
    // A duplicate frame waits for no semaphores and leaves the image alone;
    // its semaphores stay for the frame that shows it.
    [self submitWaitingFor:0 copy:NO width:0 height:0 transferOwnership:NO];
}

- (BOOL)isBusy { return _fenceUnfinished; }

- (BOOL)settleWithin:(uint64_t)timeout {
    if (!_fenceUnfinished) return YES;
    VkResult result = [self waitForFenceWithin:timeout];
    // Finished, or the device is lost: either way nothing runs any more.
    if (result != VK_SUCCESS && result != VK_ERROR_DEVICE_LOST) return NO;
    _fenceUnfinished = NO;
    URVulkanLog("The frame that did not finish in time is done (VkResult %d).", result);
    return YES;
}

- (BOOL)waitIdle {
    if (!_device) return YES;
    if (![self settleWithin:URVulkanFenceTimeout]) {
        URVulkanLog("The GPU is still busy with a frame; the core's resources stay.");
        return NO;
    }
    pthread_mutex_lock(&_queueLock);
    vkDeviceWaitIdle(_device);
    pthread_mutex_unlock(&_queueLock);
    return YES;
}

- (void)destroy {
    if (_readbackFrames > 0) {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        double scale = (double)timebase.numer / timebase.denom / 1e6 / _readbackFrames;
        URVulkanLog("%llu frames read back: %.2f ms submit and GPU wait, %.2f ms conversion per frame",
                    _readbackFrames, _readbackWaitTicks * scale, _readbackConvertTicks * scale);
        _readbackFrames = 0;
    }
    if (_device && ![self settleWithin:URVulkanFenceTimeout]) {
        // Destroying what the GPU may still use would crash the app: the
        // device, its instance and the surface's layer are left behind.
        (void)CFBridgingRetain(_layer);
        _device = VK_NULL_HANDLE;
        _surface = VK_NULL_HANDLE;
        _instance = VK_NULL_HANDLE;
        _destroyDevice = NULL;
    }
    if (_device) {
        [self waitIdle];
        if (_readback) {
            vkUnmapMemory(_device, _readbackMemory);
            vkDestroyBuffer(_device, _readback, NULL);
            vkFreeMemory(_device, _readbackMemory, NULL);
        }
        if (_fence) vkDestroyFence(_device, _fence, NULL);
        if (_commandPool) vkDestroyCommandPool(_device, _commandPool, NULL);
        _readback = VK_NULL_HANDLE;
        _readbackMemory = VK_NULL_HANDLE;
        _readbackPixels = NULL;
        _readbackSize = 0;
        _fence = VK_NULL_HANDLE;
        _commandPool = VK_NULL_HANDLE;
        _commandBuffer = VK_NULL_HANDLE;
        // The core frees its own resources while the device still exists.
        if (_destroyDevice) _destroyDevice();
        _destroyDevice = NULL;
        vkDestroyDevice(_device, NULL);
        _device = VK_NULL_HANDLE;
    }
    if (_surface) {
        vkDestroySurfaceKHR(_instance, _surface, NULL);
        _surface = VK_NULL_HANDLE;
    }
    _layer = nil;
    if (_instance) {
        vkDestroyInstance(_instance, NULL);
        _instance = VK_NULL_HANDLE;
    }
    _queue = VK_NULL_HANDLE;
    _image = VK_NULL_HANDLE;
    memset(&_interface, 0, sizeof(_interface));
}

@end

#pragma mark - retro_hw_render_interface_vulkan

static void URVulkanSetImage(void *handle, const struct retro_vulkan_image *image, uint32_t semaphoreCount,
                             const VkSemaphore *semaphores, uint32_t sourceQueueFamily) {
    URVulkanContext *context = (__bridge URVulkanContext *)handle;
    if (!context) return;
    if (image) {
        context->_image = image->create_info.image;
        context->_imageLayout = image->image_layout;
        context->_imageFormat = image->create_info.format;
        context->_imageMipLevel = image->create_info.subresourceRange.baseMipLevel;
        context->_imageArrayLayer = image->create_info.subresourceRange.baseArrayLayer;
        VkComponentMapping components = image->create_info.components;
        context->_imageMapping = (URComponentMapping){(URSwizzle)components.r, (URSwizzle)components.g,
                                                      (URSwizzle)components.b, (URSwizzle)components.a};
    } else {
        context->_image = VK_NULL_HANDLE;
    }
    if (semaphoreCount > context->_waitSemaphoreCapacity) {
        VkSemaphore *grownSemaphores = realloc(context->_waitSemaphores, semaphoreCount * sizeof(VkSemaphore));
        if (grownSemaphores) context->_waitSemaphores = grownSemaphores;
        VkPipelineStageFlags *grownStages = realloc(context->_waitStages, semaphoreCount * sizeof(VkPipelineStageFlags));
        if (grownStages) context->_waitStages = grownStages;
        if (!grownSemaphores || !grownStages) {
            // Running on without the waits would show frames that are not done.
            context->_waitSemaphoreCount = 0;
            [context failWithMessage:"Out of memory for the core's semaphores" result:VK_ERROR_OUT_OF_HOST_MEMORY];
            return;
        }
        context->_waitSemaphoreCapacity = semaphoreCount;
    }
    for (uint32_t i = 0; i < semaphoreCount; i++) {
        context->_waitSemaphores[i] = semaphores[i];
        context->_waitStages[i] = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    }
    context->_waitSemaphoreCount = semaphoreCount;
    if (semaphoreCount > 0) context->_sourceQueueFamily = sourceQueueFamily;
}

static uint32_t URVulkanGetSyncIndex(void *handle) {
    URVulkanContext *context = (__bridge URVulkanContext *)handle;
    return context ? context->_syncIndex : 0;
}

static uint32_t URVulkanGetSyncIndexMask(void *handle) {
    (void)handle;
    return (1u << URVulkanSyncIndexCount) - 1;
}

static void URVulkanSetCommandBuffers(void *handle, uint32_t count, const VkCommandBuffer *buffers) {
    URVulkanContext *context = (__bridge URVulkanContext *)handle;
    if (!context) return;
    // One more for the frame's own commands, submitted after the core's.
    if (count + 1 > context->_coreCommandBufferCapacity) {
        VkCommandBuffer *grown = realloc(context->_coreCommandBuffers, (count + 1) * sizeof(VkCommandBuffer));
        if (!grown) {
            context->_coreCommandBufferCount = 0;
            [context failWithMessage:"Out of memory for the core's command buffers" result:VK_ERROR_OUT_OF_HOST_MEMORY];
            return;
        }
        context->_coreCommandBuffers = grown;
        context->_coreCommandBufferCapacity = count + 1;
    }
    if (count) memcpy(context->_coreCommandBuffers, buffers, count * sizeof(VkCommandBuffer));
    context->_coreCommandBufferCount = count;
}

static void URVulkanWaitSyncIndex(void *handle) {
    // Every frame's GPU work is waited for when it is submitted, so only a
    // frame that did not finish in time can still run. The core may reuse
    // its resources once that is done, however long it takes: returning
    // earlier would let it overwrite or free what the GPU still uses. The
    // game stops after this retro_run anyway (-failed).
    URVulkanContext *context = (__bridge URVulkanContext *)handle;
    while (context && ![context settleWithin:URVulkanFenceTimeout]) {
        URVulkanLog("wait_sync_index: still waiting for the frame that did not finish in time.");
    }
}

static void URVulkanLockQueue(void *handle) {
    URVulkanContext *context = (__bridge URVulkanContext *)handle;
    if (context) pthread_mutex_lock(&context->_queueLock);
}

static void URVulkanUnlockQueue(void *handle) {
    URVulkanContext *context = (__bridge URVulkanContext *)handle;
    if (context) pthread_mutex_unlock(&context->_queueLock);
}

static void URVulkanSetSignalSemaphore(void *handle, VkSemaphore semaphore) {
    URVulkanContext *context = (__bridge URVulkanContext *)handle;
    if (context) context->_signalSemaphore = semaphore;
}
