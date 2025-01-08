const std = @import("std");
const models = @import("models.zig");
const vkctx = @import("vulkan_context.zig");
const gpass = @import("graphics_pass.zig");
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

    graphicsPass: gpass.GraphicsPass = undefined,

    swapchainFramebuffers: std.ArrayList(c.VkFramebuffer) = undefined,

    commandPool: c.VkCommandPool = undefined,
    commandBuffer: c.VkCommandBuffer = undefined,

    imageAvailableSemaphore: c.VkSemaphore = undefined,
    renderFinishedSemaphore: c.VkSemaphore = undefined,
    presentFence: vkrc.Fence = undefined,

    vmaAllocator: c.VmaAllocator = undefined,

    descriptorPool: vkrc.DescriptorPool = undefined,
    sceneInfoUniform: gpass.SceneInfoUniform = undefined,
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

    fn createFramebuffers(self: *VulkanRenderer) !void {
        self.swapchainFramebuffers = std.ArrayList(c.VkFramebuffer).init(std.heap.c_allocator);
        try self.swapchainFramebuffers.resize(self.swapchainImageViews.items.len);

        for (self.swapchainImageViews.items, 0..self.swapchainImageViews.items.len) |imageView, i| {
            const attachments = [_]c.VkImageView{ self.colorImageView, self.depthImageView, imageView };

            var cInfo = std.mem.zeroes(c.VkFramebufferCreateInfo);
            cInfo.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            cInfo.renderPass = self.graphicsPass.renderPass;
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

    comptime {
        if (@sizeOf(gpass.SceneInfoUniform) % 4 != 0 or @sizeOf(gpass.SceneInfoUniform) > 65536) {
            unreachable;
        }
    }

    fn createSceneUniformBuffer(self: *VulkanRenderer, uniform: *gpass.SceneInfoUniform) !void {
        const buffer = try vkrc.Buffer.init(
            self.vmaAllocator,
            @sizeOf(gpass.SceneInfoUniform),
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        );
        _ = c.vmaCopyMemoryToAllocation(self.vmaAllocator, uniform, buffer.allocation, 0, @sizeOf(gpass.SceneInfoUniform));
        self.sceneInfoUniformBuffer = buffer;

        self.descriptorPool = try vkrc.DescriptorPool.init(self.context.device);

        //alloc descriptor set
        var allocInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        allocInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocInfo.pSetLayouts = &self.graphicsPass.sceneDescriptorSetLayout;
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

        self.graphicsPass = try gpass.GraphicsPass.init(&self.context, self.swapchainFormat, self.swapchainExtent);

        try self.createFramebuffers();
        try self.createCommandPool();
        self.commandBuffer = try vkutil.allocCommandBuffer(self.context.device, self.commandPool);

        try self.createSemaphore(&self.imageAvailableSemaphore);
        try self.createSemaphore(&self.renderFinishedSemaphore);
        self.presentFence = try vkrc.Fence.init(self.context.device, c.VK_FENCE_CREATE_SIGNALED_BIT);

        placeholders.init(self.vmaAllocator);

        self.sceneInfoUniform = gpass.SceneInfoUniform{
            .lightPos = za.Vec3.new(0.0, 2.0, 0.0),
            .lightAmbient = za.Vec3.new(0.1, 0.1, 0.1),
            .lightColor = za.Vec3.new(1.0, 1.0, 1.0),
            .camPos = za.Vec3.new(0.0, 1.0, 0.0),
        };
        try self.createSceneUniformBuffer(&self.sceneInfoUniform);

        self.model = try models.Model.init(
            self.vmaAllocator,
            self.context.device,
            self.graphicsPass.materialDescriptorSetLayout,
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

        var camData = gpass.VSPushConstants{
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

        c.vkCmdUpdateBuffer(self.commandBuffer, self.sceneInfoUniformBuffer.handle, 0, @sizeOf(gpass.SceneInfoUniform), &self.sceneInfoUniform);

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
            .renderPass = self.graphicsPass.renderPass,
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

        self.graphicsPass.cmdBindGraphicsPipeline(self.commandBuffer);

        self.graphicsPass.cmdPushCamData(self.commandBuffer, &camData);

        self.graphicsPass.cmdBindSceneInfoUniform(self.commandBuffer, self.sceneInfoDescriptorSet);

        for (self.model.submeshes.items) |submesh| {
            const buffers = [_]c.VkBuffer{ submesh.posBuffer.handle, submesh.normalBuffer.handle, submesh.uvBuffer.handle, submesh.tangentBuffer.handle };
            const offsets = [_]u64{ 0, 0, 0, 0 };
            c.vkCmdBindVertexBuffers(self.commandBuffer, 0, buffers.len, &buffers, &offsets);
            c.vkCmdBindIndexBuffer(self.commandBuffer, submesh.idxBuffer.handle, 0, c.VK_INDEX_TYPE_UINT32);

            const materialDescriptor = self.model.materialDescriptors.items[submesh.materialIdx.?];
            self.graphicsPass.cmdBindMaterialUniform(self.commandBuffer, materialDescriptor);

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

        self.graphicsPass.deinit();
        self.context.deinit();
    }
};
