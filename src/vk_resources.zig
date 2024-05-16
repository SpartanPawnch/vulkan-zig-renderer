const std = @import("std");
const c = @import("c_imports.zig");

const RcError = error{
    VkDescriptorPoolCreateFailed,
    VkFenceCreateFailed,
    VkImageViewCreateFailed,
    VkSamplerCreateFailed,
};

pub fn computeMipLevels(width: u32, height: u32) u32 {
    const bits = width | height;
    const leadingZeroes = @clz(bits);
    return 32 - leadingZeroes;
}

pub const Image2D = struct {
    handle: c.VkImage,
    allocation: c.VmaAllocation,
    pub fn init(
        allocator: c.VmaAllocator,
        width: u32,
        height: u32,
        format: c.VkFormat,
        usage: c.VkImageUsageFlags,
        samples: c.VkSampleCountFlagBits,
        hasMipmaps: bool,
    ) Image2D {
        var image: c.VkImage = undefined;
        var allocation: c.VmaAllocation = undefined;
        var imageInfo = std.mem.zeroes(c.VkImageCreateInfo);
        imageInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        imageInfo.imageType = c.VK_IMAGE_TYPE_2D;
        imageInfo.format = format;
        imageInfo.extent.width = width;
        imageInfo.extent.height = height;
        imageInfo.extent.depth = 1;
        imageInfo.mipLevels = if (hasMipmaps) computeMipLevels(width, height) else 1;
        imageInfo.arrayLayers = 1;
        imageInfo.samples = samples;
        imageInfo.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        imageInfo.usage = usage;
        imageInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        imageInfo.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;

        var allocInfo = std.mem.zeroes(c.VmaAllocationCreateInfo);
        allocInfo.usage = c.VMA_MEMORY_USAGE_AUTO;

        _ = c.vmaCreateImage(allocator, &imageInfo, &allocInfo, &image, &allocation, null);
        return Image2D{ .handle = image, .allocation = allocation };
    }
    pub fn deinit(self: *Image2D, allocator: c.VmaAllocator) void {
        c.vmaDestroyImage(allocator, self.handle, self.allocation);
    }
};

pub const ImageView = struct {
    handle: c.VkImageView,
    pub fn init(device: c.VkDevice, image: c.VkImage, format: c.VkFormat) !ImageView {
        var viewInfo = std.mem.zeroes(c.VkImageViewCreateInfo);
        viewInfo.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewInfo.image = image;
        viewInfo.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        viewInfo.format = format;

        viewInfo.components.r = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.g = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.b = c.VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.a = c.VK_COMPONENT_SWIZZLE_IDENTITY;

        viewInfo.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        viewInfo.subresourceRange.baseMipLevel = 0;
        viewInfo.subresourceRange.levelCount = 1;
        viewInfo.subresourceRange.baseArrayLayer = 0;
        viewInfo.subresourceRange.layerCount = 1;

        var resView: c.VkImageView = null;
        if (c.vkCreateImageView(device, &viewInfo, null, &resView) != c.VK_SUCCESS) {
            return error.VkImageViewCreateFailed;
        }
        return ImageView{ .handle = resView };
    }
    pub fn deinit(self: *ImageView, device: c.VkDevice) void {
        c.vkDestroyImageView(device, self.handle, null);
    }
};

pub const Buffer = struct {
    handle: c.VkBuffer = null,
    allocation: c.VmaAllocation = undefined,

    pub fn init(vmaAllocator: c.VmaAllocator, size: u64, usage: c.VkBufferUsageFlags) !Buffer {
        var buffer: c.VkBuffer = undefined;
        //allocate buffer
        var cInfo = std.mem.zeroes(c.VkBufferCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        cInfo.size = size;
        cInfo.usage = usage;
        cInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        var allocation: c.VmaAllocation = undefined;
        var allocInfo = std.mem.zeroes(c.VmaAllocationCreateInfo);
        allocInfo.usage = c.VMA_MEMORY_USAGE_AUTO;
        allocInfo.flags = c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT;
        _ = c.vmaCreateBuffer(vmaAllocator, &cInfo, &allocInfo, &buffer, &allocation, null);

        return Buffer{ .handle = buffer, .allocation = allocation };
    }

    pub fn deinit(self: *Buffer, vmaAllocator: c.VmaAllocator) void {
        c.vmaDestroyBuffer(vmaAllocator, self.handle, self.allocation);
    }
};

pub const DescriptorPool = struct {
    handle: c.VkDescriptorPool = null,
    device: c.VkDevice = null,
    pub fn init(device: c.VkDevice) !DescriptorPool {
        var pools = std.mem.zeroes([2]c.VkDescriptorPoolSize);
        pools[0].type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        pools[0].descriptorCount = 2048;
        pools[1].type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        pools[1].descriptorCount = 2048;
        var cInfo = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        cInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        cInfo.poolSizeCount = pools.len;
        cInfo.pPoolSizes = &pools;
        cInfo.maxSets = 1024;

        var handle: c.VkDescriptorPool = undefined;

        if (c.vkCreateDescriptorPool(device, &cInfo, null, &handle) != c.VK_SUCCESS) {
            return error.VkDescriptorPoolCreateFailed;
        }
        return DescriptorPool{ .handle = handle, .device = device };
    }
    pub fn deinit(self: *DescriptorPool) void {
        c.vkDestroyDescriptorPool(self.device, self.handle, null);
    }
};

pub const Fence = struct {
    handle: c.VkFence = null,
    pub fn init(device: c.VkDevice, flags: c.VkFenceCreateFlags) !Fence {
        var handle: c.VkFence = undefined;
        var fenceInfo = std.mem.zeroes(c.VkFenceCreateInfo);
        fenceInfo.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fenceInfo.flags = flags;
        if (c.vkCreateFence(device, &fenceInfo, null, &handle) != c.VK_SUCCESS) {
            return error.VkFenceCreateFailed;
        }
        return Fence{ .handle = handle };
    }
    pub fn deinit(self: *Fence, device: c.VkDevice) void {
        c.vkDestroyFence(device, self.handle, null);
    }
};

pub const Sampler = struct {
    handle: c.VkSampler,
    pub fn init(device: c.VkDevice) !Sampler {
        // var props: c.VkPhysicalDeviceProperties = undefined;
        // c.vkGetPhysicalDeviceProperties(physicalDevice, &props);

        var samplerInfo = std.mem.zeroes(c.VkSamplerCreateInfo);
        samplerInfo.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        samplerInfo.magFilter = c.VK_FILTER_LINEAR;
        samplerInfo.minFilter = c.VK_FILTER_LINEAR;
        samplerInfo.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
        samplerInfo.addressModeU = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
        samplerInfo.addressModeV = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
        samplerInfo.minLod = 0.0;
        samplerInfo.maxLod = c.VK_LOD_CLAMP_NONE;
        samplerInfo.mipLodBias = 0.0;
        samplerInfo.anisotropyEnable = c.VK_FALSE;
        samplerInfo.maxAnisotropy = 0;
        samplerInfo.unnormalizedCoordinates = c.VK_FALSE;

        var sampler: c.VkSampler = undefined;
        if (c.vkCreateSampler(device, &samplerInfo, null, &sampler) != c.VK_SUCCESS) {
            return error.VkSamplerCreateFailed;
        }
        return Sampler{ .handle = sampler };
    }
    pub fn deinit(self: *Sampler, device: c.VkDevice) void {
        c.vkDestroySampler(device, self.handle, null);
    }
};
