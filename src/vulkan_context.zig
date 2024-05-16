const std = @import("std");
const models = @import("models.zig");
const vkrc = @import("vk_resources.zig");
const vkutil = @import("vk_utils.zig");
const placeholders = @import("vk_placeholders.zig");
const c = @import("c_imports.zig");
const za = @import("zalgebra");

extern fn glfwCreateWindowSurface(
    instance: c.VkInstance,
    window: *c.GLFWwindow,
    allocator: ?*const c.VkAllocationCallbacks,
    surface: *c.VkSurfaceKHR,
) c.VkResult;

pub const mainError = error{
    GlfwInitFailed,
    NoVulkan,
    WindowInitFailed,
    VkInstanceCreateFailed,
    VkDeviceCreateFailed,
    VkSurfaceCreateFailed,
    VkSwapchainCreateFailed,
    VkSwapImageViewCreateFailed,
    VkShaderModuleCreateFailed,
    VkPipelineLayoutCreateFailed,
    VkRenderPassCreateFailed,
    VkPipelineCreateFailed,
    VkFramebufferCreateFailed,
    VkCommandPoolCreateFailed,
    VkCommandBufferAllocFailed,
    VkCommandBufferBeginFailed,
    VkCommandBufferEndFailed,
    VkSemaphoreCreateFailed,
    VkFenceCreateFailed,
    VkQueueSubmitFailed,
    VkSwapImageAcquireFailed,
    VkSwapImagePresentFailed,
    VkDescriptorSetLayoutCreateFailed,
};

const SwapChainSupportDetails = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: std.ArrayList(c.VkSurfaceFormatKHR),
    presentModes: std.ArrayList(c.VkPresentModeKHR),
    fn init() SwapChainSupportDetails {
        return SwapChainSupportDetails{
            .capabilities = std.mem.zeroes(c.VkSurfaceCapabilitiesKHR),
            .formats = std.ArrayList(c.VkSurfaceFormatKHR).init(std.heap.c_allocator),
            .presentModes = std.ArrayList(c.VkPresentModeKHR).init(std.heap.c_allocator),
        };
    }

    fn deinit(self: *SwapChainSupportDetails) void {
        self.formats.deinit();
        self.presentModes.deinit();
    }
};

pub const VulkanContext = struct {
    instance: c.VkInstance = undefined,
    physicalDevice: c.VkPhysicalDevice = undefined,
    debugMessenger: c.VkDebugUtilsMessengerEXT = undefined,
    graphicsFamily: ?u32 = null,
    presentFamily: ?u32 = null,
    device: c.VkDevice = undefined,
    graphicsQueue: c.VkQueue = undefined,
    presentQueue: c.VkQueue = undefined,
    surface: c.VkSurfaceKHR = undefined,
    swapchain: c.VkSwapchainKHR = undefined,
    swapchainImages: std.ArrayList(c.VkImage) = undefined,
    swapchainFormat: u32 = undefined,
    swapchainExtent: c.VkExtent2D = undefined,
    swapchainImageViews: std.ArrayList(c.VkImageView) = undefined,

    colorImage: vkrc.Image2D = undefined,
    colorImageView: c.VkImageView = undefined,

    depthImage: vkrc.Image2D = undefined,
    depthImageView: c.VkImageView = undefined,

    renderPass: c.VkRenderPass = undefined,

    descriptorSetLayout: c.VkDescriptorSetLayout = undefined,
    graphicsLayout: c.VkPipelineLayout = undefined,
    graphicsPipeline: c.VkPipeline = undefined,

    swapchainFramebuffers: std.ArrayList(c.VkFramebuffer) = undefined,

    commandPool: c.VkCommandPool = undefined,
    commandBuffer: c.VkCommandBuffer = undefined,

    imageAvailableSemaphore: c.VkSemaphore = undefined,
    renderFinishedSemaphore: c.VkSemaphore = undefined,
    presentFence: vkrc.Fence = undefined,

    msaaSamples: c.VkSampleCountFlagBits = c.VK_SAMPLE_COUNT_1_BIT,
    vmaAllocator: c.VmaAllocator = undefined,

    model: models.Model = undefined,

    fn createInstance(self: *VulkanContext) !void {
        const appInfo: c.VkApplicationInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .apiVersion = c.VK_API_VERSION_1_3,
            .pNext = null,
            .applicationVersion = c.VK_MAKE_VERSION(0, 0, 1),
            .pApplicationName = "Kur",
            .pEngineName = null,
            .engineVersion = 1,
        };

        //resolve extensions
        var glfwExtensionCount: u32 = 0;
        const glfwExtensions = c.glfwGetRequiredInstanceExtensions(&glfwExtensionCount);

        var extensions = std.ArrayList([*]const u8).init(std.heap.c_allocator);
        try extensions.ensureTotalCapacity(glfwExtensionCount + 1);
        defer extensions.deinit();
        for (0..glfwExtensionCount) |i| {
            try extensions.append(glfwExtensions[i]);
        }
        try extensions.append(c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);

        //enable api validation
        const validationLayers = [_][*]const u8{
            "VK_LAYER_KHRONOS_validation",
        };

        const createInfo: c.VkInstanceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &appInfo,
            .enabledExtensionCount = @intCast(extensions.items.len),
            .ppEnabledExtensionNames = extensions.items.ptr,
            .enabledLayerCount = validationLayers.len,
            .ppEnabledLayerNames = &validationLayers,
            .pNext = null,
            .flags = 0,
        };

        const result = c.vkCreateInstance(&createInfo, null, &self.instance);
        if (result != c.VK_SUCCESS) {
            return error.VkInstanceCreateFailed;
        }
    }

    fn debugMessengerCallback(
        messageSeverity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
        messageType: c.VkDebugUtilsMessageTypeFlagsEXT,
        pCallbackData: *c.VkDebugUtilsMessengerCallbackDataEXT,
        pUserData: *void,
    ) c_uint {
        _ = pUserData;
        _ = messageType;

        if (messageSeverity >= c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
            std.log.warn("Validation: {s}\n", .{pCallbackData.pMessage});
        }
        return c.VK_FALSE;
    }

    fn setupDebugMessenger(self: *VulkanContext) !void {
        const createInfo = c.VkDebugUtilsMessengerCreateInfoEXT{
            .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = @ptrCast(&debugMessengerCallback),
            .pUserData = null,
            .flags = 0,
            .pNext = null,
        };

        const func: c.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(
            self.instance,
            "vkCreateDebugUtilsMessengerEXT",
        ));

        _ = func.?(
            self.instance,
            &createInfo,
            null,
            &self.debugMessenger,
        );
    }

    fn rateDevice(device: c.VkPhysicalDevice) i32 {
        var deviceProperties: c.VkPhysicalDeviceProperties = undefined;
        var deviceFeatures: c.VkPhysicalDeviceFeatures = undefined;
        c.vkGetPhysicalDeviceProperties(device, &deviceProperties);
        c.vkGetPhysicalDeviceFeatures(device, &deviceFeatures);

        var score: i32 = 0;
        if (deviceProperties.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
            score += 10000;
        }
        score += @intCast(deviceProperties.limits.maxImageDimension2D);

        return score;
    }

    fn getDeviceMaxSamples(device: c.VkPhysicalDevice) c.VkSampleCountFlagBits {
        var deviceProperties: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(device, &deviceProperties);
        const counts = deviceProperties.limits.framebufferColorSampleCounts & deviceProperties.limits.framebufferDepthSampleCounts;

        for ([_]c.VkSampleCountFlagBits{
            c.VK_SAMPLE_COUNT_64_BIT,
            c.VK_SAMPLE_COUNT_32_BIT,
            c.VK_SAMPLE_COUNT_16_BIT,
            c.VK_SAMPLE_COUNT_8_BIT,
            c.VK_SAMPLE_COUNT_4_BIT,
            c.VK_SAMPLE_COUNT_2_BIT,
        }) |bit| {
            if (counts & bit > 0) {
                return bit;
            }
        }

        return c.VK_SAMPLE_COUNT_1_BIT;
    }

    fn chooseDevice(self: *VulkanContext) !void {
        //find suitable device
        var devCount: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(self.instance, &devCount, null);
        if (devCount == 0)
            return error.VkDeviceCreateFailed;

        var devices = std.ArrayList(c.VkPhysicalDevice).init(std.heap.c_allocator);
        defer devices.deinit();
        try devices.resize(devCount);

        _ = c.vkEnumeratePhysicalDevices(self.instance, &devCount, devices.items.ptr);
        var maxScore: i32 = 0;
        self.physicalDevice = devices.items[0];
        for (devices.items) |dev| {
            const score = rateDevice(dev);
            if (score >= maxScore) {
                self.physicalDevice = dev;
                self.msaaSamples = @min(getDeviceMaxSamples(dev), c.VK_SAMPLE_COUNT_4_BIT);
                maxScore = score;
            }
        }
    }

    fn findQueueFamilies(self: *VulkanContext) void {
        var queueFamilyCount: u32 = undefined;
        c.vkGetPhysicalDeviceQueueFamilyProperties(self.physicalDevice, &queueFamilyCount, null);
        var queueFamilies = std.ArrayList(c.VkQueueFamilyProperties).init(std.heap.c_allocator);
        queueFamilies.resize(queueFamilyCount) catch unreachable;
        defer queueFamilies.deinit();
        c.vkGetPhysicalDeviceQueueFamilyProperties(self.physicalDevice, &queueFamilyCount, queueFamilies.items.ptr);
        for (queueFamilies.items, 0..queueFamilyCount) |queueFamily, i| {
            if (queueFamily.queueFlags & c.VK_QUEUE_GRAPHICS_BIT > 0) {
                self.graphicsFamily = @intCast(i);
            }

            var presentSupport: c.VkBool32 = 0;
            _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(self.physicalDevice, @intCast(i), self.surface, &presentSupport);
            if (presentSupport > 0) {
                self.presentFamily = @intCast(i);
            }
        }
    }

    fn createLogicalDevice(self: *VulkanContext) !void {
        const qPrio: f32 = 1.0;
        const allQueueFamilies = [_]u32{ self.graphicsFamily.?, self.presentFamily.? };
        const uniqueQueueFamilies = if (self.graphicsFamily.? == self.presentFamily.?) allQueueFamilies[0..1] else allQueueFamilies[0..2];

        var queueCreateInfos = std.ArrayList(c.VkDeviceQueueCreateInfo).init(std.heap.c_allocator);
        defer queueCreateInfos.deinit();

        for (uniqueQueueFamilies) |family| {
            try queueCreateInfos.append(c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = family,
                .queueCount = 1,
                .pQueuePriorities = &qPrio,
                .pNext = null,
                .flags = 0,
            });
        }

        const deviceFeatures: c.VkPhysicalDeviceFeatures = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
        const enabledExtensions = [_][*]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
        var cInfo = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pQueueCreateInfos = queueCreateInfos.items.ptr,
            .queueCreateInfoCount = @intCast(queueCreateInfos.items.len),
            .pEnabledFeatures = &deviceFeatures,
            .pNext = null,
            .ppEnabledExtensionNames = &enabledExtensions,
            .enabledExtensionCount = enabledExtensions.len,
            .ppEnabledLayerNames = null,
            .enabledLayerCount = 0,
            .flags = 0,
        };

        if (c.vkCreateDevice(self.physicalDevice, &cInfo, null, &self.device) != c.VK_SUCCESS) {
            return error.VkDeviceCreateFailed;
        }

        c.vkGetDeviceQueue(self.device, self.graphicsFamily.?, 0, &self.graphicsQueue);
        c.vkGetDeviceQueue(self.device, self.presentFamily.?, 0, &self.presentQueue);
    }

    fn createSurface(self: *VulkanContext, window: *c.GLFWwindow) !void {
        if (glfwCreateWindowSurface(self.instance, window, null, &self.surface) != c.VK_SUCCESS) {
            return error.VkSurfaceCreateFailed;
        }
    }

    fn querySwapchainSupport(self: *VulkanContext) !SwapChainSupportDetails {
        var details = SwapChainSupportDetails.init();
        _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            self.physicalDevice,
            self.surface,
            &details.capabilities,
        );

        var formatCount: u32 = undefined;
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(
            self.physicalDevice,
            self.surface,
            &formatCount,
            null,
        );
        if (formatCount != 0) {
            try details.formats.resize(formatCount);
            _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(
                self.physicalDevice,
                self.surface,
                &formatCount,
                details.formats.items.ptr,
            );
        }

        var presentModeCount: u32 = undefined;
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(
            self.physicalDevice,
            self.surface,
            &presentModeCount,
            null,
        );
        if (presentModeCount != 0) {
            try details.presentModes.resize(presentModeCount);
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(
                self.physicalDevice,
                self.surface,
                &presentModeCount,
                details.presentModes.items.ptr,
            );
        }

        return details;
    }

    fn chooseSwapSurfaceFormat(availableFormats: *std.ArrayList(c.VkSurfaceFormatKHR)) c.VkSurfaceFormatKHR {
        for (availableFormats.items) |format| {
            if (format.format == c.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                return format;
            }
        }

        return availableFormats.items[0];
    }

    fn chooseSwapPresentMode(availablePresentModes: *std.ArrayList(c.VkPresentModeKHR)) c.VkPresentModeKHR {
        for (availablePresentModes.items) |presentMode| {
            if (presentMode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                return presentMode;
            }
        }
        return c.VK_PRESENT_MODE_FIFO_KHR;
    }

    fn chooseSwapExtent(capabilities: *c.VkSurfaceCapabilitiesKHR, window: *c.GLFWwindow) c.VkExtent2D {
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return capabilities.currentExtent;
        }
        var width: i32 = undefined;
        var height: i32 = undefined;
        c.glfwGetFramebufferSize(window, &width, &height);

        var actualExtent = c.VkExtent2D{
            .width = @intCast(width),
            .height = @intCast(height),
        };
        actualExtent.width = @min(capabilities.maxImageExtent.width, @max(capabilities.minImageExtent.width, actualExtent.width));
        actualExtent.height = @min(capabilities.maxImageExtent.height, @max(capabilities.minImageExtent.height, actualExtent.height));

        return actualExtent;
    }

    fn createSwapChain(self: *VulkanContext, window: *c.GLFWwindow) !void {
        var details = try self.querySwapchainSupport();
        defer details.deinit();

        const surfaceFormat = chooseSwapSurfaceFormat(&details.formats);
        const presentMode = chooseSwapPresentMode(&details.presentModes);
        const extent = chooseSwapExtent(&details.capabilities, window);

        var imageCount = details.capabilities.minImageCount + 1;
        if (details.capabilities.maxImageCount > 0 and imageCount > details.capabilities.maxImageCount) {
            imageCount = details.capabilities.maxImageCount;
        }

        var cInfo = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
        cInfo.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        cInfo.surface = self.surface;
        cInfo.minImageCount = imageCount;
        cInfo.imageFormat = surfaceFormat.format;
        cInfo.imageColorSpace = surfaceFormat.colorSpace;
        cInfo.imageExtent = extent;
        cInfo.imageArrayLayers = 1;
        cInfo.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

        const queueFamilies = [_]u32{ self.graphicsFamily.?, self.presentFamily.? };
        if (self.graphicsFamily.? != self.presentFamily.?) {
            cInfo.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            cInfo.queueFamilyIndexCount = 2;
            cInfo.pQueueFamilyIndices = &queueFamilies;
        } else {
            cInfo.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        }

        cInfo.preTransform = details.capabilities.currentTransform;
        cInfo.compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        cInfo.presentMode = presentMode;
        cInfo.clipped = c.VK_TRUE;

        if (c.vkCreateSwapchainKHR(self.device, &cInfo, null, &self.swapchain) != c.VK_SUCCESS) {
            return error.VkSwapchainCreateFailed;
        }

        var swapchainImageCount: u32 = undefined;
        _ = c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &swapchainImageCount, null);
        self.swapchainImages = std.ArrayList(c.VkImage).init(std.heap.c_allocator);
        try self.swapchainImages.resize(swapchainImageCount);
        _ = c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &swapchainImageCount, self.swapchainImages.items.ptr);

        self.swapchainFormat = surfaceFormat.format;
        self.swapchainExtent = extent;
    }

    fn createColorBuffer(self: *VulkanContext) !void {
        self.colorImage = vkrc.Image2D.init(
            self.vmaAllocator,
            self.swapchainExtent.width,
            self.swapchainExtent.height,
            self.swapchainFormat,
            c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            self.msaaSamples,
            false,
        );

        var viewInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
        viewInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewInfo.image = self.colorImage.handle;
        viewInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        viewInfo.format = self.swapchainFormat;

        viewInfo.components.r = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.g = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.b = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.a = c.VK_COMPONENT_SWIZZLE_IDENTITY;

        viewInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        viewInfo.subresourceRange.baseMipLevel = 0;
        viewInfo.subresourceRange.levelCount = 1;
        viewInfo.subresourceRange.baseArrayLayer = 0;
        viewInfo.subresourceRange.layerCount = 1;

        if (c.vkCreateImageView(self.device, &viewInfo, null, &self.colorImageView) != c.VK_SUCCESS) {
            return error.VkSwapImageViewCreateFailed;
        }
    }

    fn createDepthBuffer(self: *VulkanContext) !void {
        self.depthImage = vkrc.Image2D.init(
            self.vmaAllocator,
            self.swapchainExtent.width,
            self.swapchainExtent.height,
            c.VK_FORMAT_D32_SFLOAT,
            c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            self.msaaSamples,
            false,
        );

        var viewInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
        viewInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewInfo.image = self.depthImage.handle;
        viewInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        viewInfo.format = c.VK_FORMAT_D32_SFLOAT;

        viewInfo.components.r = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.g = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.b = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.a = c.VK_COMPONENT_SWIZZLE_IDENTITY;

        viewInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
        viewInfo.subresourceRange.baseMipLevel = 0;
        viewInfo.subresourceRange.levelCount = 1;
        viewInfo.subresourceRange.baseArrayLayer = 0;
        viewInfo.subresourceRange.layerCount = 1;

        if (c.vkCreateImageView(self.device, &viewInfo, null, &self.depthImageView) != c.VK_SUCCESS) {
            return error.VkSwapImageViewCreateFailed;
        }
    }

    fn createImageViews(self: *VulkanContext) !void {
        self.swapchainImageViews = std.ArrayList(c.VkImageView).init(std.heap.c_allocator);
        try self.swapchainImageViews.resize(self.swapchainImages.items.len);

        for (self.swapchainImages.items, 0..self.swapchainImages.items.len) |image, i| {
            var cInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
            cInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            cInfo.image = image;
            cInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            cInfo.format = self.swapchainFormat;

            cInfo.components.r = c.VK_COMPONENT_SWIZZLE_IDENTITY;
            cInfo.components.g = c.VK_COMPONENT_SWIZZLE_IDENTITY;
            cInfo.components.b = c.VK_COMPONENT_SWIZZLE_IDENTITY;
            cInfo.components.a = c.VK_COMPONENT_SWIZZLE_IDENTITY;

            cInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
            cInfo.subresourceRange.baseMipLevel = 0;
            cInfo.subresourceRange.levelCount = 1;
            cInfo.subresourceRange.baseArrayLayer = 0;
            cInfo.subresourceRange.layerCount = 1;

            if (c.vkCreateImageView(self.device, &cInfo, null, &self.swapchainImageViews.items[i]) != c.VK_SUCCESS) {
                return error.VkSwapImageViewCreateFailed;
            }
        }
    }

    fn createDescriptorSetLayout(self: *VulkanContext) !void {
        var layoutBindings = std.mem.zeroes([2]c.VkDescriptorSetLayoutBinding);
        layoutBindings[0].binding = 0;
        layoutBindings[0].descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        layoutBindings[0].descriptorCount = 1;
        layoutBindings[0].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        layoutBindings[0].pImmutableSamplers = null;
        layoutBindings[1].binding = 1;
        layoutBindings[1].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        layoutBindings[1].descriptorCount = 1;
        layoutBindings[1].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;

        var cInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        cInfo.pBindings = &layoutBindings;
        cInfo.bindingCount = layoutBindings.len;

        if (c.vkCreateDescriptorSetLayout(self.device, &cInfo, null, &self.descriptorSetLayout) != c.VK_SUCCESS) {
            return error.VkDescriptorSetLayoutCreateFailed;
        }
    }

    fn createShaderModule(self: *VulkanContext, code: []align(@alignOf(u32)) const u8) !c.VkShaderModule {
        var cInfo = std.mem.zeroes(c.VkShaderModuleCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        cInfo.codeSize = code.len;
        cInfo.pCode = std.mem.bytesAsSlice(u32, code).ptr;

        var shaderModule: c.VkShaderModule = undefined;
        if (c.vkCreateShaderModule(self.device, &cInfo, null, &shaderModule) != c.VK_SUCCESS) {
            return error.VkShaderModuleCreateFailed;
        }
        return shaderModule;
    }

    const VSPushConstants = struct {
        viewProj: za.Mat4,
    };

    fn createGraphicsPipelineLayout(self: *VulkanContext) !void {
        var cInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        cInfo.setLayoutCount = 1;
        cInfo.pSetLayouts = &self.descriptorSetLayout;

        var pushConstantRanges = std.mem.zeroes([1]c.VkPushConstantRange);
        pushConstantRanges[0].size = @sizeOf(VSPushConstants);
        pushConstantRanges[0].stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT;

        cInfo.pushConstantRangeCount = pushConstantRanges.len;
        cInfo.pPushConstantRanges = &pushConstantRanges;

        if (c.vkCreatePipelineLayout(self.device, &cInfo, null, &self.graphicsLayout) != c.VK_SUCCESS) {
            return error.VkPipelineLayoutCreateFailed;
        }
    }

    fn createRenderPass(self: *VulkanContext) !void {
        var colorAttachment = std.mem.zeroes(c.VkAttachmentDescription);
        colorAttachment.format = self.swapchainFormat;
        colorAttachment.samples = self.msaaSamples;
        colorAttachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        colorAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        colorAttachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        colorAttachment.finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var depthAttachment = std.mem.zeroes(c.VkAttachmentDescription);
        depthAttachment.format = c.VK_FORMAT_D32_SFLOAT;
        depthAttachment.samples = self.msaaSamples;
        depthAttachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        depthAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depthAttachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        depthAttachment.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var resolveAttachment = std.mem.zeroes(c.VkAttachmentDescription);
        resolveAttachment.format = self.swapchainFormat;
        resolveAttachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        resolveAttachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        resolveAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        resolveAttachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        resolveAttachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var colorAttachmentRef = std.mem.zeroes(c.VkAttachmentReference);
        colorAttachmentRef.attachment = 0;
        colorAttachmentRef.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var depthAttachmentRef = std.mem.zeroes(c.VkAttachmentReference);
        depthAttachmentRef.attachment = 1;
        depthAttachmentRef.layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var resolveAttachmentRef = std.mem.zeroes(c.VkAttachmentReference);
        resolveAttachmentRef.attachment = 2;
        resolveAttachmentRef.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &colorAttachmentRef;
        subpass.pDepthStencilAttachment = &depthAttachmentRef;
        subpass.pResolveAttachments = &resolveAttachmentRef;

        var subpassDependecy = std.mem.zeroes(c.VkSubpassDependency);
        subpassDependecy.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        subpassDependecy.dstSubpass = 0;
        subpassDependecy.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        subpassDependecy.srcAccessMask = 0;
        subpassDependecy.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        subpassDependecy.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

        const attachments = [_]c.VkAttachmentDescription{ colorAttachment, depthAttachment, resolveAttachment };

        var cInfo = std.mem.zeroes(c.VkRenderPassCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        cInfo.attachmentCount = attachments.len;
        cInfo.pAttachments = &attachments;
        cInfo.subpassCount = 1;
        cInfo.pSubpasses = &subpass;
        cInfo.dependencyCount = 1;
        cInfo.pDependencies = &subpassDependecy;

        if (c.vkCreateRenderPass(self.device, &cInfo, null, &self.renderPass) != c.VK_SUCCESS) {
            return error.VkRenderPassCreateFailed;
        }
    }

    fn createGraphicsPipeline(self: *VulkanContext) !void {
        const vertShaderCode align(4) = @embedFile("shaders/triangle_vert.spv").*;
        const fragShaderCode align(4) = @embedFile("shaders/triangle_frag.spv").*;

        const vertShaderModule = try self.createShaderModule(&vertShaderCode);
        defer c.vkDestroyShaderModule(self.device, vertShaderModule, null);

        const fragShaderModule = try self.createShaderModule(&fragShaderCode);
        defer c.vkDestroyShaderModule(self.device, fragShaderModule, null);

        var vertShaderInfo = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        vertShaderInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        vertShaderInfo.stage = c.VK_SHADER_STAGE_VERTEX_BIT;
        vertShaderInfo.pName = "main";
        vertShaderInfo.module = vertShaderModule;

        var fragShaderInfo = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        fragShaderInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        fragShaderInfo.stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        fragShaderInfo.pName = "main";
        fragShaderInfo.module = fragShaderModule;

        var shaderStages = [_]c.VkPipelineShaderStageCreateInfo{ vertShaderInfo, fragShaderInfo };

        const dynamicStates = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };

        var dynamicState = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dynamicState.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamicState.dynamicStateCount = @intCast(dynamicStates.len);
        dynamicState.pDynamicStates = &dynamicStates;

        //inputs
        var vertexInputs = std.mem.zeroes([3]c.VkVertexInputBindingDescription);
        vertexInputs[0].binding = 0;
        vertexInputs[0].inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX;
        vertexInputs[0].stride = @sizeOf(f32) * 3;

        vertexInputs[1].binding = 1;
        vertexInputs[1].inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX;
        vertexInputs[1].stride = @sizeOf(f32) * 3;

        vertexInputs[2].binding = 2;
        vertexInputs[2].inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX;
        vertexInputs[2].stride = @sizeOf(f32) * 2;

        var vertexAttributes = std.mem.zeroes([3]c.VkVertexInputAttributeDescription);
        vertexAttributes[0].binding = 0;
        vertexAttributes[0].location = 0;
        vertexAttributes[0].format = c.VK_FORMAT_R32G32B32_SFLOAT;
        vertexAttributes[0].offset = 0;

        vertexAttributes[1].binding = 1;
        vertexAttributes[1].location = 1;
        vertexAttributes[1].format = c.VK_FORMAT_R32G32B32_SFLOAT;
        vertexAttributes[1].offset = 0;

        vertexAttributes[2].binding = 2;
        vertexAttributes[2].location = 2;
        vertexAttributes[2].format = c.VK_FORMAT_R32G32_SFLOAT;
        vertexAttributes[2].offset = 0;

        var vertexInputInfo = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertexInputInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertexInputInfo.vertexBindingDescriptionCount = vertexInputs.len;
        vertexInputInfo.pVertexBindingDescriptions = &vertexInputs;
        vertexInputInfo.vertexAttributeDescriptionCount = vertexAttributes.len;
        vertexInputInfo.pVertexAttributeDescriptions = &vertexAttributes;

        var inputAssembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        inputAssembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        inputAssembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        inputAssembly.primitiveRestartEnable = c.VK_FALSE;

        var viewport = std.mem.zeroes(c.VkViewport);
        viewport.x = 0.0;
        viewport.y = 0.0;
        viewport.width = @floatFromInt(self.swapchainExtent.width);
        viewport.height = @floatFromInt(self.swapchainExtent.height);
        viewport.minDepth = 0.0;
        viewport.maxDepth = 1.0;

        var scissor = std.mem.zeroes(c.VkRect2D);
        scissor.offset = c.VkOffset2D{ .x = 0, .y = 0 };
        scissor.extent = self.swapchainExtent;

        var viewportState = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        viewportState.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.pViewports = &viewport;
        viewportState.scissorCount = 1;
        viewportState.pScissors = &scissor;

        var rasterizer = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rasterizer.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rasterizer.depthClampEnable = c.VK_FALSE;
        rasterizer.rasterizerDiscardEnable = c.VK_FALSE;
        rasterizer.polygonMode = c.VK_POLYGON_MODE_FILL;
        rasterizer.lineWidth = 1.0;
        rasterizer.cullMode = c.VK_CULL_MODE_BACK_BIT;
        rasterizer.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rasterizer.depthBiasEnable = c.VK_FALSE;

        var multisampling = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisampling.sampleShadingEnable = c.VK_FALSE;
        multisampling.rasterizationSamples = self.msaaSamples;
        multisampling.minSampleShading = 1.0;
        multisampling.pSampleMask = null;

        var depthInfo = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        depthInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        depthInfo.depthTestEnable = c.VK_TRUE;
        depthInfo.depthWriteEnable = c.VK_TRUE;
        depthInfo.depthCompareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;
        depthInfo.depthBoundsTestEnable = c.VK_FALSE;
        depthInfo.minDepthBounds = 0.0;
        depthInfo.maxDepthBounds = 1.0;

        var colorBlendAttachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        colorBlendAttachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT |
            c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        colorBlendAttachment.blendEnable = c.VK_FALSE;
        colorBlendAttachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
        colorBlendAttachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO;
        colorBlendAttachment.colorBlendOp = c.VK_BLEND_OP_ADD;
        colorBlendAttachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        colorBlendAttachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO;
        colorBlendAttachment.alphaBlendOp = c.VK_BLEND_OP_ADD;

        var colorBlending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        colorBlending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        colorBlending.logicOpEnable = c.VK_FALSE;
        colorBlending.logicOp = c.VK_LOGIC_OP_COPY;
        colorBlending.attachmentCount = 1;
        colorBlending.pAttachments = &colorBlendAttachment;

        var cInfo = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        cInfo.stageCount = 2;
        cInfo.pStages = &shaderStages;
        cInfo.pInputAssemblyState = &inputAssembly;
        cInfo.pVertexInputState = &vertexInputInfo;
        cInfo.pViewportState = &viewportState;
        cInfo.pRasterizationState = &rasterizer;
        cInfo.pMultisampleState = &multisampling;
        cInfo.pDepthStencilState = &depthInfo;
        cInfo.pColorBlendState = &colorBlending;
        cInfo.pDynamicState = null; //&dynamicState;
        cInfo.layout = self.graphicsLayout;
        cInfo.renderPass = self.renderPass;
        cInfo.subpass = 0;

        if (c.vkCreateGraphicsPipelines(self.device, null, 1, &cInfo, null, &self.graphicsPipeline) != c.VK_SUCCESS) {
            return error.VkPipelineCreateFailed;
        }
    }

    fn createFramebuffers(self: *VulkanContext) !void {
        self.swapchainFramebuffers = std.ArrayList(c.VkFramebuffer).init(std.heap.c_allocator);
        try self.swapchainFramebuffers.resize(self.swapchainImageViews.items.len);

        for (self.swapchainImageViews.items, 0..self.swapchainImageViews.items.len) |imageView, i| {
            const attachments = [_]c.VkImageView{ self.colorImageView, self.depthImageView, imageView };

            var cInfo = std.mem.zeroes(c.VkFramebufferCreateInfo);
            cInfo.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            cInfo.renderPass = self.renderPass;
            cInfo.attachmentCount = attachments.len;
            cInfo.pAttachments = &attachments;
            cInfo.width = self.swapchainExtent.width;
            cInfo.height = self.swapchainExtent.height;
            cInfo.layers = 1;

            if (c.vkCreateFramebuffer(self.device, &cInfo, null, &self.swapchainFramebuffers.items[i]) != c.VK_SUCCESS) {
                return error.VkFramebufferCreateFailed;
            }
        }
    }

    fn createCommandPool(self: *VulkanContext) !void {
        var poolInfo = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        poolInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        poolInfo.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        poolInfo.queueFamilyIndex = self.graphicsFamily.?;
        if (c.vkCreateCommandPool(self.device, &poolInfo, null, &self.commandPool) != c.VK_SUCCESS) {
            return error.VkCommandPoolCreateFailed;
        }
    }

    fn createSemaphore(self: *VulkanContext, semaphore: *c.VkSemaphore) !void {
        var semaphoreInfo = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        semaphoreInfo.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        if (c.vkCreateSemaphore(self.device, &semaphoreInfo, null, semaphore) != c.VK_SUCCESS) {
            return error.VkSemaphoreCreateFailed;
        }
    }

    fn createVmaAllocator(self: *VulkanContext) !void {
        var cInfo = std.mem.zeroes(c.VmaAllocatorCreateInfo);
        cInfo.device = self.device;
        cInfo.physicalDevice = self.physicalDevice;
        cInfo.instance = self.instance;
        cInfo.vulkanApiVersion = c.VK_API_VERSION_1_3;

        _ = c.vmaCreateAllocator(&cInfo, &self.vmaAllocator);
    }

    pub fn init(window: *c.GLFWwindow) !VulkanContext {
        var self = VulkanContext{};
        try self.createInstance();
        try self.setupDebugMessenger();
        try self.chooseDevice();
        try self.createSurface(window);
        self.findQueueFamilies();
        try self.createLogicalDevice();
        try self.createVmaAllocator();

        try self.createSwapChain(window);
        try self.createColorBuffer();
        try self.createDepthBuffer();
        try self.createImageViews();

        try self.createRenderPass();
        try self.createDescriptorSetLayout();
        try self.createGraphicsPipelineLayout();
        try self.createGraphicsPipeline();

        try self.createFramebuffers();
        try self.createCommandPool();
        self.commandBuffer = try vkutil.allocCommandBuffer(self.device, self.commandPool);

        try self.createSemaphore(&self.imageAvailableSemaphore);
        try self.createSemaphore(&self.renderFinishedSemaphore);
        self.presentFence = try vkrc.Fence.init(self.device, c.VK_FENCE_CREATE_SIGNALED_BIT);

        placeholders.init(self.vmaAllocator);

        self.model = try models.Model.init(
            self.vmaAllocator,
            self.device,
            self.descriptorSetLayout,
            self.commandPool,
            self.graphicsQueue,
        );

        return self;
    }

    fn recordCommandBuffer(self: *VulkanContext, imageIndex: u32, cam: za.Mat4) !void {
        const beginInfo = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = 0,
            .pInheritanceInfo = null,
            .pNext = null,
        };
        if (c.vkBeginCommandBuffer(self.commandBuffer, &beginInfo) != c.VK_SUCCESS) {
            return error.VkCommandBufferBeginFailed;
        }

        const clearValues = [_]c.VkClearValue{
            .{ .color = .{ .float32 = [_]f32{ 0.1, 0.1, 0.1, 1.0 } } },
            .{ .depthStencil = .{ .depth = 0.0, .stencil = 0.0 } },
            .{ .color = .{ .float32 = [_]f32{ 0.1, 0.1, 0.1, 1.0 } } },
        };

        const renderPassBeginInfo = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = self.renderPass,
            .framebuffer = self.swapchainFramebuffers.items[imageIndex],
            .renderArea = c.VkRect2D{
                .extent = self.swapchainExtent,
                .offset = c.VkOffset2D{ .x = 0, .y = 0 },
            },
            .clearValueCount = clearValues.len,
            .pClearValues = &clearValues,
            .pNext = null,
        };

        c.vkCmdBeginRenderPass(self.commandBuffer, &renderPassBeginInfo, c.VK_SUBPASS_CONTENTS_INLINE);

        c.vkCmdBindPipeline(self.commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphicsPipeline);

        var projection = za.Mat4.perspectiveReversedZ(
            60.0,
            @as(f32, @floatFromInt(self.swapchainExtent.width)) / @as(f32, @floatFromInt(self.swapchainExtent.height)),
            0.1,
        );

        projection.data[1][1] *= -1.0;

        var camData = VSPushConstants{
            .viewProj = projection.mul(cam.inv()),
        };
        c.vkCmdPushConstants(self.commandBuffer, self.graphicsLayout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(VSPushConstants), &camData);

        for (self.model.submeshes.items) |submesh| {
            const buffers = [_]c.VkBuffer{ submesh.posBuffer.handle, submesh.normalBuffer.handle, submesh.uvBuffer.handle };
            const offsets = [_]u64{ 0, 0, 0 };
            c.vkCmdBindVertexBuffers(self.commandBuffer, 0, buffers.len, &buffers, &offsets);
            c.vkCmdBindIndexBuffer(self.commandBuffer, submesh.idxBuffer.handle, 0, c.VK_INDEX_TYPE_UINT32);

            const materialDescriptor = self.model.materialDescriptors.items[submesh.materialIdx.?];
            c.vkCmdBindDescriptorSets(self.commandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphicsLayout, 0, 1, &materialDescriptor, 0, null);

            c.vkCmdDrawIndexed(self.commandBuffer, submesh.idxCount, 1, 0, 0, 0);
        }

        c.vkCmdEndRenderPass(self.commandBuffer);

        if (c.vkEndCommandBuffer(self.commandBuffer) != c.VK_SUCCESS) {
            return error.VkCommandBufferEndFailed;
        }
    }
    pub fn draw(self: *VulkanContext, window: *c.GLFWwindow, cam: za.Mat4) !void {
        _ = c.vkWaitForFences(self.device, 1, &self.presentFence.handle, c.VK_TRUE, c.UINT64_MAX);
        _ = c.vkResetFences(self.device, 1, &self.presentFence.handle);

        var imageIndex: u32 = undefined;
        {
            const result = c.vkAcquireNextImageKHR(self.device, self.swapchain, c.UINT64_MAX, self.imageAvailableSemaphore, null, &imageIndex);

            if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
                try self.recreateSwapchain(window);
                return;
            } else if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
                return error.VkSwapImageAcquireFailed;
            }
        }

        _ = c.vkResetCommandBuffer(self.commandBuffer, 0);

        try self.recordCommandBuffer(imageIndex, cam);

        var submitInfo = std.mem.zeroes(c.VkSubmitInfo);
        submitInfo.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;

        const waitSemaphores = [_]c.VkSemaphore{self.imageAvailableSemaphore};
        const waitStages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        submitInfo.waitSemaphoreCount = 1;
        submitInfo.pWaitSemaphores = &waitSemaphores;
        submitInfo.pWaitDstStageMask = &waitStages;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &self.commandBuffer;

        const signalSemaphores = [_]c.VkSemaphore{self.renderFinishedSemaphore};
        submitInfo.signalSemaphoreCount = 1;
        submitInfo.pSignalSemaphores = &signalSemaphores;

        if (c.vkQueueSubmit(self.graphicsQueue, 1, &submitInfo, self.presentFence.handle) != c.VK_SUCCESS) {
            return error.VkQueueSubmitFailed;
        }

        var presentInfo = std.mem.zeroes(c.VkPresentInfoKHR);
        presentInfo.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        presentInfo.waitSemaphoreCount = 1;
        presentInfo.pWaitSemaphores = &signalSemaphores;
        const swapchains = [_]c.VkSwapchainKHR{self.swapchain};
        presentInfo.swapchainCount = swapchains.len;
        presentInfo.pSwapchains = &swapchains;
        presentInfo.pImageIndices = &imageIndex;
        presentInfo.pResults = null;

        const result = c.vkQueuePresentKHR(self.graphicsQueue, &presentInfo);
        if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR) {
            try self.recreateSwapchain(window);
        } else if (result != c.VK_SUCCESS) {
            return error.VkSwapImagePresentFailed;
        }
    }

    fn cleanupSwapchain(self: *VulkanContext) void {
        c.vkDestroyImageView(self.device, self.depthImageView, null);
        self.depthImage.deinit(self.vmaAllocator);

        c.vkDestroyImageView(self.device, self.colorImageView, null);
        self.colorImage.deinit(self.vmaAllocator);

        for (self.swapchainFramebuffers.items) |framebuffer| {
            c.vkDestroyFramebuffer(self.device, framebuffer, null);
        }

        for (self.swapchainImageViews.items) |imageView| {
            c.vkDestroyImageView(self.device, imageView, null);
        }

        c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
    }

    fn recreateSwapchain(self: *VulkanContext, window: *c.GLFWwindow) !void {
        _ = c.vkDeviceWaitIdle(self.device);

        self.cleanupSwapchain();

        try self.createSwapChain(window);
        try self.createColorBuffer();
        try self.createDepthBuffer();
        try self.createImageViews();
        try self.createFramebuffers();
    }

    fn destroyDebugMessenger(self: *VulkanContext) void {
        const func: c.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(
            self.instance,
            "vkDestroyDebugUtilsMessengerEXT",
        ));
        func.?(self.instance, self.debugMessenger, null);
    }

    pub fn deinit(self: *VulkanContext) void {
        //wait for everything to finish so we can exit cleanly
        _ = c.vkDeviceWaitIdle(self.device);

        self.model.deinit(self.device, self.vmaAllocator);
        placeholders.deinit(self.vmaAllocator);

        self.cleanupSwapchain();

        self.swapchainFramebuffers.deinit();

        self.swapchainImageViews.deinit();
        self.swapchainImages.deinit();

        c.vmaDestroyAllocator(self.vmaAllocator);

        self.presentFence.deinit(self.device);
        c.vkDestroySemaphore(self.device, self.imageAvailableSemaphore, null);
        c.vkDestroySemaphore(self.device, self.renderFinishedSemaphore, null);

        c.vkDestroyCommandPool(self.device, self.commandPool, null);

        c.vkDestroyPipeline(self.device, self.graphicsPipeline, null);
        c.vkDestroyPipelineLayout(self.device, self.graphicsLayout, null);
        c.vkDestroyDescriptorSetLayout(self.device, self.descriptorSetLayout, null);
        c.vkDestroyRenderPass(self.device, self.renderPass, null);

        c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        c.vkDestroyDevice(self.device, null);
        self.destroyDebugMessenger();
        c.vkDestroyInstance(self.instance, null);
    }
};
