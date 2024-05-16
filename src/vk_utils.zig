const std = @import("std");
const c = @import("c_imports.zig");

const UtilError = error{
    VkCommandBufferAllocFailed,
};

pub fn allocCommandBuffer(device: c.VkDevice, commandPool: c.VkCommandPool) !c.VkCommandBuffer {
    var cmdbuf: c.VkCommandBuffer = undefined;
    var allocInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.commandPool = commandPool;
    allocInfo.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandBufferCount = 1;

    if (c.vkAllocateCommandBuffers(device, &allocInfo, &cmdbuf) != c.VK_SUCCESS) {
        return error.VkCommandBufferAllocFailed;
    }
    return cmdbuf;
}

pub fn image_barrier(
    commandBuffer: c.VkCommandBuffer,
    image: c.VkImage,
    srcAccessMask: c.VkAccessFlags,
    dstAccessMask: c.VkAccessFlags,
    srcLayout: c.VkImageLayout,
    dstLayout: c.VkImageLayout,
    srcStageMask: c.VkPipelineStageFlags,
    dstStageMask: c.VkPipelineStageFlags,
    resourceRange: c.VkImageSubresourceRange,
    srcQueueFamily: u32,
    dstQueueFamily: u32,
) void {
    var ibarrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    ibarrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    ibarrier.image = image;
    ibarrier.srcAccessMask = srcAccessMask;
    ibarrier.dstAccessMask = dstAccessMask;
    ibarrier.srcQueueFamilyIndex = srcQueueFamily;
    ibarrier.dstQueueFamilyIndex = dstQueueFamily;
    ibarrier.oldLayout = srcLayout;
    ibarrier.newLayout = dstLayout;
    ibarrier.subresourceRange = resourceRange;
    c.vkCmdPipelineBarrier(commandBuffer, srcStageMask, dstStageMask, 0, 0, null, 0, null, 1, &ibarrier);
}
