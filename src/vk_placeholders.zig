const std = @import("std");
const c = @import("c_imports.zig");
const vkrc = @import("vk_resources.zig");

pub var whiteTex: vkrc.Image2D = undefined;
pub var blackTex: vkrc.Image2D = undefined;

pub fn init(allocator: c.VmaAllocator) void {
    whiteTex = vkrc.Image2D.init(
        allocator,
        1,
        1,
        c.VK_FORMAT_R8G8B8A8_SRGB,
        c.VK_IMAGE_USAGE_SAMPLED_BIT,
        1,
        false,
    );
    blackTex = vkrc.Image2D.init(
        allocator,
        1,
        1,
        c.VK_FORMAT_R8G8B8A8_SRGB,
        c.VK_IMAGE_USAGE_SAMPLED_BIT,
        1,
        false,
    );
}
pub fn deinit(allocator: c.VmaAllocator) void {
    whiteTex.deinit(allocator);
    blackTex.deinit(allocator);
}
