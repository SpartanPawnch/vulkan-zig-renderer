const std = @import("std");
const c = @import("c_imports.zig");
const glfw = @import("mach-glfw");

pub const VkContextError = error{
    GlfwInitFailed,
    NoVulkan,
    WindowInitFailed,
    VkInstanceCreateFailed,
    VkDeviceCreateFailed,
    VkSurfaceCreateFailed,
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

    msaaSamples: c.VkSampleCountFlagBits = c.VK_SAMPLE_COUNT_1_BIT,

    fn createInstance(self: *VulkanContext) !void {
        const appInfo: c.VkApplicationInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .apiVersion = c.VK_API_VERSION_1_3,
            .pNext = null,
            .applicationVersion = c.VK_MAKE_VERSION(0, 0, 1),
            .pApplicationName = "Sponza Renderer",
            .pEngineName = null,
            .engineVersion = 1,
        };

        //resolve extensions
        const glfwExtensions = glfw.getRequiredInstanceExtensions() orelse unreachable;

        var extensions = std.ArrayList([*]const u8).init(std.heap.c_allocator);
        try extensions.ensureTotalCapacity(glfwExtensions.len + 1);
        defer extensions.deinit();
        for (0..glfwExtensions.len) |i| {
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

        var deviceFeatures: c.VkPhysicalDeviceFeatures = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
        deviceFeatures.samplerAnisotropy = c.VK_TRUE;
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

    fn createSurface(self: *VulkanContext, window: glfw.Window) !void {
        if (glfw.createWindowSurface(self.instance, window, null, &self.surface) != c.VK_SUCCESS) {
            return error.VkSurfaceCreateFailed;
        }
    }
    pub fn init(window: glfw.Window) !VulkanContext {
        var self = VulkanContext{};
        try self.createInstance();
        try self.setupDebugMessenger();
        try self.chooseDevice();
        try self.createSurface(window);
        self.findQueueFamilies();
        try self.createLogicalDevice();
        return self;
    }

    fn destroyDebugMessenger(self: *VulkanContext) void {
        const func: c.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(
            self.instance,
            "vkDestroyDebugUtilsMessengerEXT",
        ));
        func.?(self.instance, self.debugMessenger, null);
    }
    pub fn deinit(self: *VulkanContext) void {
        c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        c.vkDestroyDevice(self.device, null);
        self.destroyDebugMessenger();
        c.vkDestroyInstance(self.instance, null);
    }
};
