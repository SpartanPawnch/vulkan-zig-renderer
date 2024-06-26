const std = @import("std");
const c = @import("c_imports.zig");
const vkctx = @import("vulkan_context.zig");
const za = @import("zalgebra");

pub const VSPushConstants = struct {
    viewProj: za.Mat4,
};

pub const MaterialUniform = struct {
    baseColorFactor: za.Vec4 = undefined,
    metallicFactor: f32 = 0.0,
    roughnessFactor: f32 = 0.0,
};

pub const SceneInfoUniform align(1) = struct {
    lightPos: za.Vec3,
    _pad0: f32 = 0,
    lightColor: za.Vec3,
    _pad1: f32 = 0,
    lightAmbient: za.Vec3,
    _pad2: f32 = 0,
    camPos: za.Vec3,
};

pub const GraphicsPass = struct {
    context: *vkctx.VulkanContext = undefined,
    renderPass: c.VkRenderPass = undefined,
    materialDescriptorSetLayout: c.VkDescriptorSetLayout = undefined,
    sceneDescriptorSetLayout: c.VkDescriptorSetLayout = undefined,
    graphicsLayout: c.VkPipelineLayout = undefined,
    graphicsPipeline: c.VkPipeline = undefined,

    fn createMaterialDescriptorSetLayout(self: *GraphicsPass) !void {
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

    fn createSceneInfoDescriptorSetLayout(self: *GraphicsPass) !void {
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

    fn createShaderModule(self: *GraphicsPass, code: []align(@alignOf(u32)) const u8) !c.VkShaderModule {
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

    fn createGraphicsPipelineLayout(self: *GraphicsPass) !void {
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

    fn createRenderPass(self: *GraphicsPass, swapchainFormat: c.VkFormat) !void {
        var colorAttachment = std.mem.zeroes(c.VkAttachmentDescription);
        colorAttachment.format = swapchainFormat;
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
        resolveAttachment.format = swapchainFormat;
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

    fn createGraphicsPipeline(self: *GraphicsPass, swapchainExtent: c.VkExtent2D) !void {
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
        viewport.width = @floatFromInt(swapchainExtent.width);
        viewport.height = @floatFromInt(swapchainExtent.height);
        viewport.minDepth = 0.0;
        viewport.maxDepth = 1.0;

        var scissor = std.mem.zeroes(c.VkRect2D);
        scissor.offset = c.VkOffset2D{ .x = 0, .y = 0 };
        scissor.extent = swapchainExtent;

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

    pub fn init(context: *vkctx.VulkanContext, swapchainFormat: c.VkFormat, swapchainExtent: c.VkExtent2D) !GraphicsPass {
        var self = GraphicsPass{};
        self.context = context;

        try self.createRenderPass(swapchainFormat);
        try self.createMaterialDescriptorSetLayout();
        try self.createSceneInfoDescriptorSetLayout();
        try self.createGraphicsPipelineLayout();
        try self.createGraphicsPipeline(swapchainExtent);

        return self;
    }
    pub fn deinit(self: *GraphicsPass) void {
        c.vkDestroyPipeline(self.context.device, self.graphicsPipeline, null);
        c.vkDestroyPipelineLayout(self.context.device, self.graphicsLayout, null);
        c.vkDestroyDescriptorSetLayout(self.context.device, self.sceneDescriptorSetLayout, null);
        c.vkDestroyDescriptorSetLayout(self.context.device, self.materialDescriptorSetLayout, null);
        c.vkDestroyRenderPass(self.context.device, self.renderPass, null);
    }
};
