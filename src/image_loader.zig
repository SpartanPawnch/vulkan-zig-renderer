const c = @cImport({
    @cInclude("stb_image.h");
});
const cvk = @import("c_imports.zig");
const vkrc = @import("vk_resources.zig");
const vkutil = @import("vk_utils.zig");
const std = @import("std");

const allocator = std.heap.page_allocator;

const ImageLoadError = error{
    ImageLoadFailed,
};

pub fn loadImage2D(
    path: []const u8,
    device: cvk.VkDevice,
    vmaAllocator: cvk.VmaAllocator,
    cmdPool: cvk.VkCommandPool,
    graphicsQueue: cvk.VkQueue,
    format: cvk.VkFormat,
) !vkrc.Image2D {
    var widthI: i32 = undefined;
    var heightI: i32 = undefined;
    var channels: i32 = undefined;

    const data = c.stbi_load(@ptrCast(path), &widthI, &heightI, &channels, 4);
    if (data == null) {
        return error.ImageLoadFailed;
    }
    const width: u32 = @intCast(widthI);
    const height: u32 = @intCast(heightI);

    const imgSize = width * height * 4;

    const image = vkrc.Image2D.init(
        vmaAllocator,
        width,
        height,
        format,
        cvk.VK_IMAGE_USAGE_SAMPLED_BIT | cvk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | cvk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        cvk.VK_SAMPLE_COUNT_1_BIT,
        true,
    );

    var stagingBuf = try vkrc.Buffer.init(vmaAllocator, imgSize, cvk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    defer stagingBuf.deinit(vmaAllocator);

    _ = cvk.vmaCopyMemoryToAllocation(
        vmaAllocator,
        data,
        stagingBuf.allocation,
        0,
        imgSize,
    );

    c.stbi_image_free(data);

    var cmdBuf = try vkutil.allocCommandBuffer(device, cmdPool);
    defer cvk.vkFreeCommandBuffers(device, cmdPool, 1, &cmdBuf);

    //upload base image
    var beginInfo = std.mem.zeroes(cvk.VkCommandBufferBeginInfo);
    beginInfo.sType = cvk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    _ = cvk.vkBeginCommandBuffer(cmdBuf, &beginInfo);

    var copy = std.mem.zeroes(cvk.VkBufferImageCopy);
    copy.bufferOffset = 0;
    copy.bufferRowLength = 0;
    copy.bufferImageHeight = 0;
    copy.imageSubresource = cvk.VkImageSubresourceLayers{
        .aspectMask = cvk.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseArrayLayer = 0,
        .layerCount = 1,
        .mipLevel = 0,
    };
    copy.imageOffset = cvk.VkOffset3D{
        .x = 0,
        .y = 0,
        .z = 0,
    };
    copy.imageExtent = cvk.VkExtent3D{
        .width = width,
        .height = height,
        .depth = 1,
    };

    const mipLevels = vkrc.computeMipLevels(width, height);

    vkutil.image_barrier(
        cmdBuf,
        image.handle,
        0,
        cvk.VK_ACCESS_TRANSFER_WRITE_BIT,
        cvk.VK_IMAGE_LAYOUT_UNDEFINED,
        cvk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        cvk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        cvk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        cvk.VkImageSubresourceRange{
            .aspectMask = cvk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = mipLevels,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        cvk.VK_QUEUE_FAMILY_IGNORED,
        cvk.VK_QUEUE_FAMILY_IGNORED,
    );

    cvk.vkCmdCopyBufferToImage(
        cmdBuf,
        stagingBuf.handle,
        image.handle,
        cvk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &copy,
    );

    vkutil.image_barrier(
        cmdBuf,
        image.handle,
        cvk.VK_ACCESS_TRANSFER_WRITE_BIT,
        cvk.VK_ACCESS_TRANSFER_READ_BIT,
        cvk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        cvk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        cvk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        cvk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        cvk.VkImageSubresourceRange{
            .aspectMask = cvk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        cvk.VK_QUEUE_FAMILY_IGNORED,
        cvk.VK_QUEUE_FAMILY_IGNORED,
    );

    //generate mips
    var mipWidth = width;
    var mipHeight = height;
    for (1..mipLevels) |level| {
        var blit = std.mem.zeroes(cvk.VkImageBlit);
        blit.srcSubresource = cvk.VkImageSubresourceLayers{
            .aspectMask = cvk.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = @intCast(level - 1),
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        blit.srcOffsets[0] = cvk.VkOffset3D{ .x = 0, .y = 0, .z = 0 };
        blit.srcOffsets[1] = cvk.VkOffset3D{ .x = @intCast(mipWidth), .y = @intCast(mipHeight), .z = 1 };
        mipWidth >>= 1;
        if (mipWidth == 0) mipWidth = 1;
        mipHeight >>= 1;
        if (mipHeight == 0) mipHeight = 1;

        blit.dstSubresource = cvk.VkImageSubresourceLayers{
            .aspectMask = cvk.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = @intCast(level),
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        blit.dstOffsets[0] = cvk.VkOffset3D{ .x = 0, .y = 0, .z = 0 };
        blit.dstOffsets[1] = cvk.VkOffset3D{ .x = @intCast(mipWidth), .y = @intCast(mipHeight), .z = 1 };

        cvk.vkCmdBlitImage(
            cmdBuf,
            image.handle,
            cvk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            image.handle,
            cvk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &blit,
            cvk.VK_FILTER_LINEAR,
        );

        vkutil.image_barrier(
            cmdBuf,
            image.handle,
            cvk.VK_ACCESS_TRANSFER_WRITE_BIT,
            cvk.VK_ACCESS_TRANSFER_READ_BIT,
            cvk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            cvk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            cvk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            cvk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            cvk.VkImageSubresourceRange{
                .aspectMask = cvk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = @intCast(level),
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            cvk.VK_QUEUE_FAMILY_IGNORED,
            cvk.VK_QUEUE_FAMILY_IGNORED,
        );
    }

    vkutil.image_barrier(
        cmdBuf,
        image.handle,
        cvk.VK_ACCESS_TRANSFER_READ_BIT,
        cvk.VK_ACCESS_SHADER_READ_BIT,
        cvk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        cvk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        cvk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        cvk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        cvk.VkImageSubresourceRange{
            .aspectMask = cvk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = mipLevels,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        cvk.VK_QUEUE_FAMILY_IGNORED,
        cvk.VK_QUEUE_FAMILY_IGNORED,
    );

    _ = cvk.vkEndCommandBuffer(cmdBuf);

    var uploadComplete = try vkrc.Fence.init(device, 0);
    defer uploadComplete.deinit(device);
    var submitInfo = std.mem.zeroes(cvk.VkSubmitInfo);
    submitInfo.sType = cvk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.pCommandBuffers = &cmdBuf;
    submitInfo.commandBufferCount = 1;
    _ = cvk.vkQueueSubmit(graphicsQueue, 1, &submitInfo, uploadComplete.handle);
    _ = cvk.vkWaitForFences(device, 1, &uploadComplete.handle, cvk.VK_TRUE, std.math.maxInt(u64));

    return image;
}
