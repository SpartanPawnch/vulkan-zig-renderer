const std = @import("std");
const c = @import("c_imports.zig");
const vkrc = @import("vk_resources.zig");
const Gltf = @import("zgltf");
const za = @import("zalgebra");
const img_loader = @import("image_loader.zig");

const ModelError = error{
    VkBufferCreateFailed,
    VkBufferNoSuitableMemType,
    VkBufferAllocateFailed,
    VkDescriptorSetAllocFailed,
};

const allocator = std.heap.page_allocator;

pub const MaterialUniform = struct {
    baseColorFactor: za.Vec4 = undefined,
    metallicFactor: f32 = 0.0,
    roughnessFactor: f32 = 0.0,
};

pub const Model = struct {
    const SubMesh = struct {
        posBuffer: vkrc.Buffer,
        normalBuffer: vkrc.Buffer,
        uvBuffer: vkrc.Buffer,
        tangentBuffer: vkrc.Buffer,
        idxBuffer: vkrc.Buffer,
        idxCount: u32 = 0,
        materialIdx: ?usize = null,
    };
    submeshes: std.ArrayList(SubMesh),
    dPool: vkrc.DescriptorPool,
    materialBuffers: std.ArrayList(vkrc.Buffer),
    materialDescriptors: std.ArrayList(c.VkDescriptorSet),
    sampler: vkrc.Sampler,
    images: std.ArrayList(vkrc.Image2D),
    imageViews: std.ArrayList(vkrc.ImageView),

    fn processPrimitive(primitive: *Gltf.Primitive, gltfCtx: *Gltf, bin: []const u8, vmaAllocator: c.VmaAllocator) !SubMesh {
        var indices = std.ArrayList(u32).init(allocator);
        defer indices.deinit();

        var positions = std.ArrayList(f32).init(allocator);
        defer positions.deinit();

        var normals = std.ArrayList(f32).init(allocator);
        defer normals.deinit();

        var texcoords = std.ArrayList(f32).init(allocator);
        defer texcoords.deinit();

        var tangents = std.ArrayList(f32).init(allocator);
        defer tangents.deinit();

        {
            const accessor = gltfCtx.data.accessors.items[primitive.indices.?];
            switch (accessor.component_type) {
                Gltf.ComponentType.byte => {
                    var bufViewIndices = std.ArrayList(i8).init(allocator);
                    defer bufViewIndices.deinit();
                    gltfCtx.getDataFromBufferView(i8, &bufViewIndices, accessor, bin);
                    for (bufViewIndices.items) |idx| {
                        try indices.append(@intCast(idx));
                    }
                },
                Gltf.ComponentType.short => {
                    var bufViewIndices = std.ArrayList(i16).init(allocator);
                    defer bufViewIndices.deinit();
                    gltfCtx.getDataFromBufferView(i16, &bufViewIndices, accessor, bin);
                    for (bufViewIndices.items) |idx| {
                        try indices.append(@intCast(idx));
                    }
                },
                Gltf.ComponentType.unsigned_byte => {
                    var bufViewIndices = std.ArrayList(u8).init(allocator);
                    defer bufViewIndices.deinit();
                    gltfCtx.getDataFromBufferView(u8, &bufViewIndices, accessor, bin);
                    for (bufViewIndices.items) |idx| {
                        try indices.append(@intCast(idx));
                    }
                },
                Gltf.ComponentType.unsigned_short => {
                    var bufViewIndices = std.ArrayList(u16).init(allocator);
                    defer bufViewIndices.deinit();
                    gltfCtx.getDataFromBufferView(u16, &bufViewIndices, accessor, bin);
                    for (bufViewIndices.items) |idx| {
                        try indices.append(@intCast(idx));
                    }
                },
                Gltf.ComponentType.unsigned_integer => {
                    var bufViewIndices = std.ArrayList(u32).init(allocator);
                    defer bufViewIndices.deinit();
                    gltfCtx.getDataFromBufferView(u32, &bufViewIndices, accessor, bin);
                    for (bufViewIndices.items) |idx| {
                        try indices.append(@intCast(idx));
                    }
                },
                else => {},
            }
        }
        for (primitive.attributes.items) |attribute| {
            switch (attribute) {
                .position => |idx| {
                    const accessor = gltfCtx.data.accessors.items[idx];
                    gltfCtx.getDataFromBufferView(f32, &positions, accessor, bin);
                },
                .normal => |idx| {
                    const accessor = gltfCtx.data.accessors.items[idx];
                    gltfCtx.getDataFromBufferView(f32, &normals, accessor, bin);
                },
                .texcoord => |idx| {
                    const accessor = gltfCtx.data.accessors.items[idx];
                    gltfCtx.getDataFromBufferView(f32, &texcoords, accessor, bin);
                },
                .tangent => |idx| {
                    const accessor = gltfCtx.data.accessors.items[idx];
                    gltfCtx.getDataFromBufferView(f32, &tangents, accessor, bin);
                },
                else => {},
            }
        }

        if (tangents.items.len == 0) {
            try tangents.resize((positions.items.len / 3) * 4);
        }

        const posBuffer = try vkrc.Buffer.init(
            vmaAllocator,
            positions.items.len * @sizeOf(f32),
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        );
        const normalBuffer = try vkrc.Buffer.init(
            vmaAllocator,
            normals.items.len * @sizeOf(f32),
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        );
        const uvBuffer = try vkrc.Buffer.init(
            vmaAllocator,
            texcoords.items.len * @sizeOf(f32),
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        );
        const tangentBuffer = try vkrc.Buffer.init(
            vmaAllocator,
            tangents.items.len * @sizeOf(f32),
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        );
        const idxBuffer = try vkrc.Buffer.init(
            vmaAllocator,
            indices.items.len * @sizeOf(u32),
            c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        );

        // std.debug.print("{any}\n", .{tangents.items});

        //transfer data
        _ = c.vmaCopyMemoryToAllocation(
            vmaAllocator,
            positions.items.ptr,
            posBuffer.allocation,
            0,
            positions.items.len * @sizeOf(f32),
        );
        _ = c.vmaCopyMemoryToAllocation(
            vmaAllocator,
            normals.items.ptr,
            normalBuffer.allocation,
            0,
            normals.items.len * @sizeOf(f32),
        );
        _ = c.vmaCopyMemoryToAllocation(
            vmaAllocator,
            texcoords.items.ptr,
            uvBuffer.allocation,
            0,
            texcoords.items.len * @sizeOf(f32),
        );
        _ = c.vmaCopyMemoryToAllocation(
            vmaAllocator,
            tangents.items.ptr,
            tangentBuffer.allocation,
            0,
            tangents.items.len * @sizeOf(f32),
        );
        _ = c.vmaCopyMemoryToAllocation(
            vmaAllocator,
            indices.items.ptr,
            idxBuffer.allocation,
            0,
            indices.items.len * @sizeOf(u32),
        );

        return SubMesh{
            .posBuffer = posBuffer,
            .normalBuffer = normalBuffer,
            .uvBuffer = uvBuffer,
            .tangentBuffer = tangentBuffer,
            .idxBuffer = idxBuffer,
            .idxCount = @intCast(indices.items.len),
            .materialIdx = primitive.material,
        };
    }

    pub fn init(
        vmaAllocator: c.VmaAllocator,
        device: c.VkDevice,
        setLayout: c.VkDescriptorSetLayout,
        cmdPool: c.VkCommandPool,
        graphicsQueue: c.VkQueue,
    ) !Model {
        var executableDirBuf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const executableDir = try std.fs.selfExeDirPath(&executableDirBuf);
        var executableDirFd = try std.fs.openDirAbsolute(executableDir, .{});
        const buf = try executableDirFd.readFileAllocOptions(
            allocator,
            "assets/sponza/Sponza.gltf",
            std.math.maxInt(u64),
            null,
            4,
            null,
        );
        defer allocator.free(buf);

        const bin = try executableDirFd.readFileAllocOptions(
            allocator,
            "assets/sponza/Sponza.bin",
            std.math.maxInt(u64),
            null,
            4,
            null,
        );
        defer allocator.free(bin);

        var gltfCtx = Gltf.init(allocator);
        defer gltfCtx.deinit();

        try gltfCtx.parse(buf);

        // load submeshes
        var submeshes = std.ArrayList(SubMesh).init(allocator);

        for (gltfCtx.data.meshes.items) |*mesh| {
            for (mesh.primitives.items) |*primitive| {
                try submeshes.append(try processPrimitive(primitive, &gltfCtx, bin, vmaAllocator));
            }
        }

        //create sampler
        const sampler = try vkrc.Sampler.init(device);

        const ImageUsage = enum {
            ColorTexture,
            MetallicRoughness,
            NormalMap,
        };

        // get image usages
        var imageUsages = std.ArrayList(ImageUsage).init(allocator);
        defer imageUsages.deinit();
        try imageUsages.resize(gltfCtx.data.images.items.len);
        for (gltfCtx.data.materials.items) |*material| {
            if (material.metallic_roughness.base_color_texture != null) {
                imageUsages.items[material.metallic_roughness.base_color_texture.?.index] = ImageUsage.ColorTexture;
            }
            if (material.metallic_roughness.metallic_roughness_texture != null) {
                imageUsages.items[material.metallic_roughness.metallic_roughness_texture.?.index] = ImageUsage.MetallicRoughness;
            }
            if (material.normal_texture != null) {
                imageUsages.items[material.normal_texture.?.index] = ImageUsage.NormalMap;
            }
        }

        // load images
        var images = std.ArrayList(vkrc.Image2D).init(allocator);
        var imageViews = std.ArrayList(vkrc.ImageView).init(allocator);
        var whiteIdx: ?usize = null;
        for (gltfCtx.data.images.items, 0..gltfCtx.data.images.items.len) |*image, idx| {
            // std.debug.print("{?s}\n", .{image.uri});
            const uri = image.uri.?;
            const root = "assets/sponza/";
            if (std.mem.startsWith(u8, uri, "white")) {
                whiteIdx = images.items.len;
            }
            var path = std.ArrayList(u8).init(allocator);
            defer path.deinit();
            try path.appendSlice(root);
            try path.appendSlice(uri);

            var format: c.VkFormat = undefined;
            if (imageUsages.items[idx] == ImageUsage.ColorTexture) {
                format = c.VK_FORMAT_R8G8B8A8_SRGB;
            } else {
                format = c.VK_FORMAT_R8G8B8A8_UNORM;
            }

            const resImg = try img_loader.loadImage2D(path.items, device, vmaAllocator, cmdPool, graphicsQueue, format);
            try images.append(resImg);
            try imageViews.append(try vkrc.ImageView.init(device, resImg.handle, format));
        }

        //upload material data
        var materialBuffers = std.ArrayList(vkrc.Buffer).init(allocator);

        for (gltfCtx.data.materials.items) |mat| {
            const matData = MaterialUniform{
                .baseColorFactor = za.Vec4.fromSlice(&mat.metallic_roughness.base_color_factor),
                .metallicFactor = mat.metallic_roughness.metallic_factor,
                .roughnessFactor = mat.metallic_roughness.roughness_factor,
            };
            try materialBuffers.append(try vkrc.Buffer.init(vmaAllocator, @sizeOf(MaterialUniform), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT));
            _ = c.vmaCopyMemoryToAllocation(vmaAllocator, &matData, materialBuffers.getLast().allocation, 0, @sizeOf(MaterialUniform));
        }

        //create material descriptors
        const dPool = try vkrc.DescriptorPool.init(device);
        var materialDescriptors = std.ArrayList(c.VkDescriptorSet).init(allocator);
        try materialDescriptors.resize(materialBuffers.items.len);

        for (0..materialBuffers.items.len) |i| {
            var allocInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            allocInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            allocInfo.descriptorPool = dPool.handle;
            allocInfo.descriptorSetCount = 1;
            allocInfo.pSetLayouts = &setLayout;

            if (c.vkAllocateDescriptorSets(device, &allocInfo, &materialDescriptors.items[i]) != c.VK_SUCCESS) {
                return error.VkDescriptorSetAllocFailed;
            }
        }

        //write material descriptors
        var writes = std.ArrayList(c.VkWriteDescriptorSet).init(allocator);
        defer writes.deinit();
        try writes.resize(materialBuffers.items.len * 4);

        var bufInfos = std.ArrayList(c.VkDescriptorBufferInfo).init(allocator);
        defer bufInfos.deinit();
        try bufInfos.resize(materialBuffers.items.len);

        var texInfos = std.ArrayList(c.VkDescriptorImageInfo).init(allocator);
        defer texInfos.deinit();
        try texInfos.resize(materialDescriptors.items.len * 3);

        for (0..materialBuffers.items.len, gltfCtx.data.materials.items) |i, mat| {
            bufInfos.items[i].offset = 0;
            bufInfos.items[i].buffer = materialBuffers.items[i].handle;
            bufInfos.items[i].range = c.VK_WHOLE_SIZE;

            writes.items[4 * i] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes.items[4 * i].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes.items[4 * i].dstSet = materialDescriptors.items[i];
            writes.items[4 * i].dstBinding = 0;
            writes.items[4 * i].descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            writes.items[4 * i].descriptorCount = 1;
            writes.items[4 * i].pBufferInfo = &bufInfos.items[i];

            {
                const texIdx = mat.metallic_roughness.base_color_texture.?;
                const imgIdx = gltfCtx.data.textures.items[texIdx.index].source.?;
                texInfos.items[3 * i].imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                texInfos.items[3 * i].imageView = imageViews.items[imgIdx].handle;
                texInfos.items[3 * i].sampler = sampler.handle;

                writes.items[4 * i + 1] = std.mem.zeroes(c.VkWriteDescriptorSet);
                writes.items[4 * i + 1].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes.items[4 * i + 1].dstSet = materialDescriptors.items[i];
                writes.items[4 * i + 1].dstBinding = 1;
                writes.items[4 * i + 1].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                writes.items[4 * i + 1].descriptorCount = 1;
                writes.items[4 * i + 1].pImageInfo = &texInfos.items[3 * i];
            }

            {
                var imgIdx: usize = undefined;
                if (mat.metallic_roughness.metallic_roughness_texture != null) {
                    const texIdx = mat.metallic_roughness.metallic_roughness_texture.?.index;
                    imgIdx = gltfCtx.data.textures.items[texIdx].source.?;
                } else {
                    imgIdx = whiteIdx.?;
                }
                texInfos.items[3 * i + 1].imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                texInfos.items[3 * i + 1].imageView = imageViews.items[imgIdx].handle;
                texInfos.items[3 * i + 1].sampler = sampler.handle;

                writes.items[4 * i + 2] = std.mem.zeroes(c.VkWriteDescriptorSet);
                writes.items[4 * i + 2].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes.items[4 * i + 2].dstSet = materialDescriptors.items[i];
                writes.items[4 * i + 2].dstBinding = 2;
                writes.items[4 * i + 2].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                writes.items[4 * i + 2].descriptorCount = 1;
                writes.items[4 * i + 2].pImageInfo = &texInfos.items[3 * i + 1];
            }

            {
                if (mat.normal_texture != null) {
                    const texIdx = mat.normal_texture.?;
                    const imgIdx = gltfCtx.data.textures.items[texIdx.index].source.?;

                    texInfos.items[3 * i + 2].imageView = imageViews.items[imgIdx].handle;
                } else {
                    texInfos.items[3 * i + 2].imageView = imageViews.items[whiteIdx.?].handle;
                }

                texInfos.items[3 * i + 2].imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                texInfos.items[3 * i + 2].sampler = sampler.handle;

                writes.items[4 * i + 3] = std.mem.zeroes(c.VkWriteDescriptorSet);
                writes.items[4 * i + 3].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes.items[4 * i + 3].dstSet = materialDescriptors.items[i];
                writes.items[4 * i + 3].dstBinding = 3;
                writes.items[4 * i + 3].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                writes.items[4 * i + 3].descriptorCount = 1;
                writes.items[4 * i + 3].pImageInfo = &texInfos.items[3 * i + 2];
            }
        }

        c.vkUpdateDescriptorSets(device, @intCast(writes.items.len), writes.items.ptr, 0, null);

        return Model{
            .submeshes = submeshes,
            .materialBuffers = materialBuffers,
            .materialDescriptors = materialDescriptors,
            .dPool = dPool,
            .images = images,
            .imageViews = imageViews,
            .sampler = sampler,
        };
    }
    pub fn deinit(self: *Model, device: c.VkDevice, vmaAllocator: c.VmaAllocator) void {
        self.materialDescriptors.deinit();
        for (self.materialBuffers.items) |*buf| {
            buf.deinit(vmaAllocator);
        }
        self.materialBuffers.deinit();
        self.dPool.deinit();

        for (self.imageViews.items) |*view| {
            view.deinit(device);
        }
        self.imageViews.deinit();

        for (self.images.items) |*image| {
            image.deinit(vmaAllocator);
        }
        self.images.deinit();

        self.sampler.deinit(device);

        for (self.submeshes.items) |*submesh| {
            submesh.idxBuffer.deinit(vmaAllocator);
            submesh.tangentBuffer.deinit(vmaAllocator);
            submesh.uvBuffer.deinit(vmaAllocator);
            submesh.normalBuffer.deinit(vmaAllocator);
            submesh.posBuffer.deinit(vmaAllocator);
        }
        self.submeshes.deinit();
    }
};
