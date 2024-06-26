const std = @import("std");
const models = @import("models.zig");
const vkctx = @import("vulkan_context.zig");
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

pub const VulkanRenderer = struct {
    context: vkctx.VulkanContext = undefined,
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

    materialDescriptorSetLayout: c.VkDescriptorSetLayout = undefined,
    sceneDescriptorSetLayout: c.VkDescriptorSetLayout = undefined,
    graphicsLayout: c.VkPipelineLayout = undefined,
    graphicsPipeline: c.VkPipeline = undefined,

    swapchainFramebuffers: std.ArrayList(c.VkFramebuffer) = undefined,

    commandPool: c.VkCommandPool = undefined,
    commandBuffer: c.VkCommandBuffer = undefined,

    imageAvailableSemaphore: c.VkSemaphore = undefined,
    renderFinishedSemaphore: c.VkSemaphore = undefined,
    presentFence: vkrc.Fence = undefined,

    vmaAllocator: c.VmaAllocator = undefined,

    descriptorPool: vkrc.DescriptorPool = undefined,
    sceneInfoUniform: SceneInfoUniform = undefined,
    sceneInfoUniformBuffer: vkrc.Buffer = undefined,
    sceneInfoDescriptorSet: c.VkDescriptorSet = undefined,

    model: models.Model = undefined,

    fn querySwapchainSupport(self: *VulkanRenderer) !SwapChainSupportDetails {
        var details = SwapChainSupportDetails.init();
        _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            self.context.physicalDevice,
            self.context.surface,
            &details.capabilities,
        );

        var formatCount: u32 = undefined;
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(
            self.context.physicalDevice,
            self.context.surface,
            &formatCount,
            null,
        );
        if (formatCount != 0) {
            try details.formats.resize(formatCount);
            _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(
                self.context.physicalDevice,
                self.context.surface,
                &formatCount,
                details.formats.items.ptr,
            );
        }

        var presentModeCount: u32 = undefined;
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(
            self.context.physicalDevice,
            self.context.surface,
            &presentModeCount,
            null,
        );
        if (presentModeCount != 0) {
            try details.presentModes.resize(presentModeCount);
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(
                self.context.physicalDevice,
                self.context.surface,
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

    fn createSwapChain(self: *VulkanRenderer, window: *c.GLFWwindow) !void {
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
        cInfo.surface = self.context.surface;
        cInfo.minImageCount = imageCount;
        cInfo.imageFormat = surfaceFormat.format;
        cInfo.imageColorSpace = surfaceFormat.colorSpace;
        cInfo.imageExtent = extent;
        cInfo.imageArrayLayers = 1;
        cInfo.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

        const queueFamilies = [_]u32{ self.context.graphicsFamily.?, self.context.presentFamily.? };
        if (self.context.graphicsFamily.? != self.context.presentFamily.?) {
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

        if (c.vkCreateSwapchainKHR(self.context.device, &cInfo, null, &self.swapchain) != c.VK_SUCCESS) {
            return error.VkSwapchainCreateFailed;
        }

        var swapchainImageCount: u32 = undefined;
        _ = c.vkGetSwapchainImagesKHR(self.context.device, self.swapchain, &swapchainImageCount, null);
        self.swapchainImages = std.ArrayList(c.VkImage).init(std.heap.c_allocator);
        try self.swapchainImages.resize(swapchainImageCount);
        _ = c.vkGetSwapchainImagesKHR(self.context.device, self.swapchain, &swapchainImageCount, self.swapchainImages.items.ptr);

        self.swapchainFormat = surfaceFormat.format;
        self.swapchainExtent = extent;
    }

    fn createColorBuffer(self: *VulkanRenderer) !void {
        self.colorImage = vkrc.Image2D.init(
            self.vmaAllocator,
            self.swapchainExtent.width,
            self.swapchainExtent.height,
            self.swapchainFormat,
            c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            self.context.msaaSamples,
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

        if (c.vkCreateImageView(self.context.device, &viewInfo, null, &self.colorImageView) != c.VK_SUCCESS) {
            return error.VkSwapImageViewCreateFailed;
        }
    }

    fn createDepthBuffer(self: *VulkanRenderer) !void {
        self.depthImage = vkrc.Image2D.init(
            self.vmaAllocator,
            self.swapchainExtent.width,
            self.swapchainExtent.height,
            c.VK_FORMAT_D32_SFLOAT,
            c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            self.context.msaaSamples,
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

        if (c.vkCreateImageView(self.context.device, &viewInfo, null, &self.depthImageView) != c.VK_SUCCESS) {
            return error.VkSwapImageViewCreateFailed;
        }
    }

    fn createImageViews(self: *VulkanRenderer) !void {
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

            if (c.vkCreateImageView(self.context.device, &cInfo, null, &self.swapchainImageViews.items[i]) != c.VK_SUCCESS) {
                return error.VkSwapImageViewCreateFailed;
            }
        }
    }

    fn createMaterialDescriptorSetLayout(self: *VulkanRenderer) !void {
        var layoutBindings = std.mem.zeroes([4]c.VkDescriptorSetLayoutBinding);
        layoutBindings[0].binding = 0;
        layoutBindings[0].descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        layoutBindings[0].descriptorCount = 1;
        layoutBindings[0].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        layoutBindings[0].pImmutableSamplers = null;

        layoutBindings[1].binding = 1;
        layoutBindings[1].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        layoutBindings[1].descriptorCount = 1;
        layoutBindings[1].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;

        layoutBindings[2].binding = 2;
        layoutBindings[2].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        layoutBindings[2].descriptorCount = 1;
        layoutBindings[2].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;

        layoutBindings[3].binding = 3;
        layoutBindings[3].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        layoutBindings[3].descriptorCount = 1;
        layoutBindings[3].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;

        var cInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        cInfo.pBindings = &layoutBindings;
        cInfo.bindingCount = layoutBindings.len;

        if (c.vkCreateDescriptorSetLayout(self.context.device, &cInfo, null, &self.materialDescriptorSetLayout) != c.VK_SUCCESS) {
            return error.VkDescriptorSetLayoutCreateFailed;
        }
    }

    fn createSceneInfoDescriptorSetLayout(self: *VulkanRenderer) !void {
        var layoutBindings = std.mem.zeroes([1]c.VkDescriptorSetLayoutBinding);
        layoutBindings[0].binding = 0;
        layoutBindings[0].descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        layoutBindings[0].descriptorCount = 1;
        layoutBindings[0].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        layoutBindings[0].pImmutableSamplers = null;

        var cInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        cInfo.pBindings = &layoutBindings;
        cInfo.bindingCount = layoutBindings.len;

        if (c.vkCreateDescriptorSetLayout(self.context.device, &cInfo, null, &self.sceneDescriptorSetLayout) != c.VK_SUCCESS) {
            return error.VkDescriptorSetLayoutCreateFailed;
        }
    }

    fn createShaderModule(self: *VulkanRenderer, code: []align(@alignOf(u32)) const u8) !c.VkShaderModule {
        var cInfo = std.mem.zeroes(c.VkShaderModuleCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        cInfo.codeSize = code.len;
        cInfo.pCode = std.mem.bytesAsSlice(u32, code).ptr;

        var shaderModule: c.VkShaderModule = undefined;
        if (c.vkCreateShaderModule(self.context.device, &cInfo, null, &shaderModule) != c.VK_SUCCESS) {
            return error.VkShaderModuleCreateFailed;
        }
        return shaderModule;
    }

    const VSPushConstants = struct {
        viewProj: za.Mat4,
    };

    fn createGraphicsPipelineLayout(self: *VulkanRenderer) !void {
        const setLayouts = [2]c.VkDescriptorSetLayout{ self.materialDescriptorSetLayout, self.sceneDescriptorSetLayout };
        var cInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        cInfo.setLayoutCount = setLayouts.len;
        cInfo.pSetLayouts = &setLayouts;

        var pushConstantRanges = std.mem.zeroes([1]c.VkPushConstantRange);
        pushConstantRanges[0].size = @sizeOf(VSPushConstants);
        pushConstantRanges[0].stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT;

        cInfo.pushConstantRangeCount = pushConstantRanges.len;
        cInfo.pPushConstantRanges = &pushConstantRanges;

        if (c.vkCreatePipelineLayout(self.context.device, &cInfo, null, &self.graphicsLayout) != c.VK_SUCCESS) {
            return error.VkPipelineLayoutCreateFailed;
        }
    }

    fn createRenderPass(self: *VulkanRenderer) !void {
        var colorAttachment = std.mem.zeroes(c.VkAttachmentDescription);
        colorAttachment.format = self.swapchainFormat;
        colorAttachment.samples = self.context.msaaSamples;
        colorAttachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        colorAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        colorAttachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        colorAttachment.finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var depthAttachment = std.mem.zeroes(c.VkAttachmentDescription);
        depthAttachment.format = c.VK_FORMAT_D32_SFLOAT;
        depthAttachment.samples = self.context.msaaSamples;
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

        if (c.vkCreateRenderPass(self.context.device, &cInfo, null, &self.renderPass) != c.VK_SUCCESS) {
            return error.VkRenderPassCreateFailed;
        }
    }

    fn createGraphicsPipeline(self: *VulkanRenderer) !void {
        const vertShaderCode align(4) = @embedFile("shaders/triangle_vert.spv").*;
        const fragShaderCode align(4) = @embedFile("shaders/triangle_frag.spv").*;

        const vertShaderModule = try self.createShaderModule(&vertShaderCode);
        defer c.vkDestroyShaderModule(self.context.device, vertShaderModule, null);

        const fragShaderModule = try self.createShaderModule(&fragShaderCode);
        defer c.vkDestroyShaderModule(self.context.device, fragShaderModule, null);

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
        var vertexInputs = std.mem.zeroes([4]c.VkVertexInputBindingDescription);
        vertexInputs[0].binding = 0;
        vertexInputs[0].inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX;
        vertexInputs[0].stride = @sizeOf(f32) * 3;

        vertexInputs[1].binding = 1;
        vertexInputs[1].inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX;
        vertexInputs[1].stride = @sizeOf(f32) * 3;

        vertexInputs[2].binding = 2;
        vertexInputs[2].inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX;
        vertexInputs[2].stride = @sizeOf(f32) * 2;

        vertexInputs[3].binding = 3;
        vertexInputs[3].inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX;
        vertexInputs[3].stride = @sizeOf(f32) * 4;

        var vertexAttributes = std.mem.zeroes([4]c.VkVertexInputAttributeDescription);
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

        vertexAttributes[3].binding = 3;
        vertexAttributes[3].location = 3;
        vertexAttributes[3].format = c.VK_FORMAT_R32G32B32A32_SFLOAT;
        vertexAttributes[3].offset = 0;

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
        multisampling.rasterizationSamples = self.context.msaaSamples;
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

        if (c.vkCreateGraphicsPipelines(self.context.device, null, 1, &cInfo, null, &self.graphicsPipeline) != c.VK_SUCCESS) {
            return error.VkPipelineCreateFailed;
        }
    }

    fn createFramebuffers(self: *VulkanRenderer) !void {
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

            if (c.vkCreateFramebuffer(self.context.device, &cInfo, null, &self.swapchainFramebuffers.items[i]) != c.VK_SUCCESS) {
                return error.VkFramebufferCreateFailed;
            }
        }
    }

    fn createCommandPool(self: *VulkanRenderer) !void {
        var poolInfo = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        poolInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        poolInfo.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        poolInfo.queueFamilyIndex = self.context.graphicsFamily.?;
        if (c.vkCreateCommandPool(self.context.device, &poolInfo, null, &self.commandPool) != c.VK_SUCCESS) {
            return error.VkCommandPoolCreateFailed;
        }
    }

    fn createSemaphore(self: *VulkanRenderer, semaphore: *c.VkSemaphore) !void {
        var semaphoreInfo = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        semaphoreInfo.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        if (c.vkCreateSemaphore(self.context.device, &semaphoreInfo, null, semaphore) != c.VK_SUCCESS) {
            return error.VkSemaphoreCreateFailed;
        }
    }

    fn createVmaAllocator(self: *VulkanRenderer) !void {
        var cInfo = std.mem.zeroes(c.VmaAllocatorCreateInfo);
        cInfo.device = self.context.device;
        cInfo.physicalDevice = self.context.physicalDevice;
        cInfo.instance = self.context.instance;
        cInfo.vulkanApiVersion = c.VK_API_VERSION_1_3;

        _ = c.vmaCreateAllocator(&cInfo, &self.vmaAllocator);
    }

    const SceneInfoUniform align(1) = struct {
        lightPos: za.Vec3,
        _pad0: f32 = 0,
        lightColor: za.Vec3,
        _pad1: f32 = 0,
        lightAmbient: za.Vec3,
        _pad2: f32 = 0,
        camPos: za.Vec3,
    };

    comptime {
        if (@sizeOf(SceneInfoUniform) % 4 != 0 or @sizeOf(SceneInfoUniform) > 65536) {
            unreachable;
        }
    }

    fn createSceneUniformBuffer(self: *VulkanRenderer, uniform: *SceneInfoUniform) !void {
        const buffer = try vkrc.Buffer.init(
            self.vmaAllocator,
            @sizeOf(SceneInfoUniform),
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        );
        _ = c.vmaCopyMemoryToAllocation(self.vmaAllocator, uniform, buffer.allocation, 0, @sizeOf(SceneInfoUniform));
        self.sceneInfoUniformBuffer = buffer;

        self.descriptorPool = try vkrc.DescriptorPool.init(self.context.device);

        //alloc descriptor set
        var allocInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        allocInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocInfo.pSetLayouts = &self.sceneDescriptorSetLayout;
        allocInfo.descriptorSetCount = 1;
        allocInfo.descriptorPool = self.descriptorPool.handle;
        _ = c.vkAllocateDescriptorSets(self.context.device, &allocInfo, &self.sceneInfoDescriptorSet);

        //write descriptor set
        const bufferInfo = c.VkDescriptorBufferInfo{
            .buffer = self.sceneInfoUniformBuffer.handle,
            .offset = 0,
            .range = c.VK_WHOLE_SIZE,
        };
        var descriptorWrite = std.mem.zeroes(c.VkWriteDescriptorSet);
        descriptorWrite.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        descriptorWrite.dstSet = self.sceneInfoDescriptorSet;
        descriptorWrite.dstBinding = 0;
        descriptorWrite.descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        descriptorWrite.pBufferInfo = &bufferInfo;
        descriptorWrite.descriptorCount = 1;
        _ = c.vkUpdateDescriptorSets(self.context.device, 1, &descriptorWrite, 0, null);
    }

    pub fn init(window: *c.GLFWwindow) !VulkanRenderer {
        var self = VulkanRenderer{};
        self.context = try vkctx.VulkanContext.init(window);
        try self.createVmaAllocator();

        try self.createSwapChain(window);
        try self.createColorBuffer();
        try self.createDepthBuffer();
        try self.createImageViews();

        try self.createRenderPass();
        try self.createMaterialDescriptorSetLayout();
        try self.createSceneInfoDescriptorSetLayout();
        try self.createGraphicsPipelineLayout();
        try self.createGraphicsPipeline();

        try self.createFramebuffers();
        try self.createCommandPool();
        self.commandBuffer = try vkutil.allocCommandBuffer(self.context.device, self.commandPool);

        try self.createSemaphore(&self.imageAvailableSemaphore);
        try self.createSemaphore(&self.renderFinishedSemaphore);
        self.presentFence = try vkrc.Fence.init(self.context.device, c.VK_FENCE_CREATE_SIGNALED_BIT);

        placeholders.init(self.vmaAllocator);

        self.sceneInfoUniform = SceneInfoUniform{
            .lightPos = za.Vec3.fromSlice(&[_]f32{ 0.0, 2.0, 0.0 }),
            .lightAmbient = za.Vec3.fromSlice(&[_]f32{ 0.1, 0.1, 0.1 }),
            .lightColor = za.Vec3.fromSlice(&[_]f32{ 1.0, 1.0, 1.0 }),
            .camPos = za.Vec3.fromSlice(&[_]f32{ 0.0, 1.0, 0.0 }),
        };
        try self.createSceneUniformBuffer(&self.sceneInfoUniform);

        self.model = try models.Model.init(
            self.vmaAllocator,
            self.context.device,
            self.materialDescriptorSetLayout,
            self.commandPool,
            self.context.graphicsQueue,
        );

        return self;
    }

    fn recordCommandBuffer(self: *VulkanRenderer, imageIndex: u32, cam: za.Mat4) !void {
        const beginInfo = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = 0,
            .pInheritanceInfo = null,
            .pNext = null,
        };
        if (c.vkBeginCommandBuffer(self.commandBuffer, &beginInfo) != c.VK_SUCCESS) {
            return error.VkCommandBufferBeginFailed;
        }

        //update camera
        var projection = za.Mat4.perspectiveReversedZ(
            60.0,
            @as(f32, @floatFromInt(self.swapchainExtent.width)) / @as(f32, @floatFromInt(self.swapchainExtent.height)),
            0.1,
        );

        projection.data[1][1] *= -1.0;

        var camData = VSPushConstants{
            .viewProj = projection.mul(cam.inv()),
        };
        const camPos = cam.mulByVec4(za.Vec4.fromSlice(&[_]f32{ 0.0, 0.0, 0.0, 1.0 }));
        self.sceneInfoUniform.camPos = camPos.toVec3();

        //update uniform
        vkutil.buffer_barrier(
            self.commandBuffer,
            self.sceneInfoUniformBuffer.handle,
            c.VK_ACCESS_UNIFORM_READ_BIT,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
            c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_WHOLE_SIZE,
            0,
            c.VK_QUEUE_FAMILY_IGNORED,
            c.VK_QUEUE_FAMILY_IGNORED,
        );

        c.vkCmdUpdateBuffer(self.commandBuffer, self.sceneInfoUniformBuffer.handle, 0, @sizeOf(SceneInfoUniform), &self.sceneInfoUniform);

        vkutil.buffer_barrier(
            self.commandBuffer,
            self.sceneInfoUniformBuffer.handle,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
            c.VK_ACCESS_UNIFORM_READ_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            c.VK_WHOLE_SIZE,
            0,
            c.VK_QUEUE_FAMILY_IGNORED,
            c.VK_QUEUE_FAMILY_IGNORED,
        );

        //begin renderpass
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

        c.vkCmdPushConstants(self.commandBuffer, self.graphicsLayout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(VSPushConstants), &camData);

        c.vkCmdBindDescriptorSets(
            self.commandBuffer,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.graphicsLayout,
            1,
            1,
            &self.sceneInfoDescriptorSet,
            0,
            null,
        );

        for (self.model.submeshes.items) |submesh| {
            const buffers = [_]c.VkBuffer{ submesh.posBuffer.handle, submesh.normalBuffer.handle, submesh.uvBuffer.handle, submesh.tangentBuffer.handle };
            const offsets = [_]u64{ 0, 0, 0, 0 };
            c.vkCmdBindVertexBuffers(self.commandBuffer, 0, buffers.len, &buffers, &offsets);
            c.vkCmdBindIndexBuffer(self.commandBuffer, submesh.idxBuffer.handle, 0, c.VK_INDEX_TYPE_UINT32);

            const materialDescriptor = self.model.materialDescriptors.items[submesh.materialIdx.?];
            c.vkCmdBindDescriptorSets(
                self.commandBuffer,
                c.VK_PIPELINE_BIND_POINT_GRAPHICS,
                self.graphicsLayout,
                0,
                1,
                &materialDescriptor,
                0,
                null,
            );

            c.vkCmdDrawIndexed(self.commandBuffer, submesh.idxCount, 1, 0, 0, 0);
        }

        c.vkCmdEndRenderPass(self.commandBuffer);

        if (c.vkEndCommandBuffer(self.commandBuffer) != c.VK_SUCCESS) {
            return error.VkCommandBufferEndFailed;
        }
    }
    pub fn draw(self: *VulkanRenderer, window: *c.GLFWwindow, cam: za.Mat4) !void {
        _ = c.vkWaitForFences(self.context.device, 1, &self.presentFence.handle, c.VK_TRUE, c.UINT64_MAX);
        _ = c.vkResetFences(self.context.device, 1, &self.presentFence.handle);

        var imageIndex: u32 = undefined;
        {
            const result = c.vkAcquireNextImageKHR(self.context.device, self.swapchain, c.UINT64_MAX, self.imageAvailableSemaphore, null, &imageIndex);

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

        if (c.vkQueueSubmit(self.context.graphicsQueue, 1, &submitInfo, self.presentFence.handle) != c.VK_SUCCESS) {
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

        const result = c.vkQueuePresentKHR(self.context.graphicsQueue, &presentInfo);
        if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR) {
            try self.recreateSwapchain(window);
        } else if (result != c.VK_SUCCESS) {
            return error.VkSwapImagePresentFailed;
        }
    }

    fn cleanupSwapchain(self: *VulkanRenderer) void {
        c.vkDestroyImageView(self.context.device, self.depthImageView, null);
        self.depthImage.deinit(self.vmaAllocator);

        c.vkDestroyImageView(self.context.device, self.colorImageView, null);
        self.colorImage.deinit(self.vmaAllocator);

        for (self.swapchainFramebuffers.items) |framebuffer| {
            c.vkDestroyFramebuffer(self.context.device, framebuffer, null);
        }

        for (self.swapchainImageViews.items) |imageView| {
            c.vkDestroyImageView(self.context.device, imageView, null);
        }

        c.vkDestroySwapchainKHR(self.context.device, self.swapchain, null);
    }

    fn recreateSwapchain(self: *VulkanRenderer, window: *c.GLFWwindow) !void {
        _ = c.vkDeviceWaitIdle(self.context.device);

        self.cleanupSwapchain();

        try self.createSwapChain(window);
        try self.createColorBuffer();
        try self.createDepthBuffer();
        try self.createImageViews();
        try self.createFramebuffers();
    }

    fn destroyDebugMessenger(self: *VulkanRenderer) void {
        const func: c.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(
            self.instance,
            "vkDestroyDebugUtilsMessengerEXT",
        ));
        func.?(self.instance, self.debugMessenger, null);
    }

    pub fn deinit(self: *VulkanRenderer) void {
        //wait for everything to finish so we can exit cleanly
        _ = c.vkDeviceWaitIdle(self.context.device);

        self.model.deinit(self.context.device, self.vmaAllocator);
        placeholders.deinit(self.vmaAllocator);

        self.sceneInfoUniformBuffer.deinit(self.vmaAllocator);
        self.descriptorPool.deinit();

        self.cleanupSwapchain();

        self.swapchainFramebuffers.deinit();

        self.swapchainImageViews.deinit();
        self.swapchainImages.deinit();

        c.vmaDestroyAllocator(self.vmaAllocator);

        self.presentFence.deinit(self.context.device);
        c.vkDestroySemaphore(self.context.device, self.imageAvailableSemaphore, null);
        c.vkDestroySemaphore(self.context.device, self.renderFinishedSemaphore, null);

        c.vkDestroyCommandPool(self.context.device, self.commandPool, null);

        c.vkDestroyPipeline(self.context.device, self.graphicsPipeline, null);
        c.vkDestroyPipelineLayout(self.context.device, self.graphicsLayout, null);
        c.vkDestroyDescriptorSetLayout(self.context.device, self.sceneDescriptorSetLayout, null);
        c.vkDestroyDescriptorSetLayout(self.context.device, self.materialDescriptorSetLayout, null);
        c.vkDestroyRenderPass(self.context.device, self.renderPass, null);

        self.context.deinit();
    }
};
