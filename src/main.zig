const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan_renderer.zig");
const za = @import("zalgebra");

const CamState = struct {
    mouseX: f64 = 0.0,
    mouseY: f64 = 0.0,
    prevX: f64 = 0.0,
    prevY: f64 = 0.0,
    cam: za.Mat4 = za.Mat4.identity(),
    forward: bool = false,
    back: bool = false,
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    mousing: bool = false,
    wasMousing: bool = false,
};

fn glfwCallbackKeyPress(window: glfw.Window, key: glfw.Key, scanCode: c_int, action: glfw.Action, _: glfw.Mods) void {
    const state = window.getUserPointer(CamState) orelse return;
    _ = scanCode;
    const isReleased = (action == glfw.Action.release);
    switch (key) {
        glfw.Key.w => {
            state.forward = !isReleased;
        },
        glfw.Key.s => {
            state.back = !isReleased;
        },
        glfw.Key.a => {
            state.left = !isReleased;
        },
        glfw.Key.d => {
            state.right = !isReleased;
        },
        glfw.Key.e => {
            state.up = !isReleased;
        },
        glfw.Key.q => {
            state.down = !isReleased;
        },
        else => {},
    }
}

fn glfwCallbackButton(window: glfw.Window, button: glfw.MouseButton, action: glfw.Action, _: glfw.Mods) void {
    const state = window.getUserPointer(CamState) orelse return;
    if (button == glfw.MouseButton.right and action == glfw.Action.press) {
        state.mousing = !state.mousing;
        if (state.mousing) {
            window.setInputModeCursor(.disabled);
        } else {
            window.setInputModeCursor(.normal);
        }
    }
}

fn glfwCallbackMotion(window: glfw.Window, x: f64, y: f64) void {
    const state = window.getUserPointer(CamState) orelse return;
    state.mouseX = x;
    state.mouseY = y;
}
fn updateCamera(state: *CamState, deltaTime: f64) void {
    const cam = &(state.cam);

    if (state.mousing) {
        if (state.wasMousing) {
            const sensitivity = 0.01;
            const dx: f32 = @floatCast(sensitivity * (state.mouseX - state.prevX));
            const dy: f32 = @floatCast(sensitivity * (state.mouseY - state.prevY));

            cam.* = cam.*.mul(za.Mat4.fromRotation(za.toDegrees(-dy), za.Vec3.fromSlice(&[_]f32{ 1.0, 0.0, 0.0 })));
            cam.* = cam.*.mul(za.Mat4.fromRotation(za.toDegrees(-dx), za.Vec3.fromSlice(&[_]f32{ 0.0, 1.0, 0.0 })));
        }

        state.prevX = state.mouseX;
        state.prevY = state.mouseY;
        state.wasMousing = true;
    } else {
        state.wasMousing = false;
    }

    const deltaDist: f32 = @floatCast(deltaTime);

    if (state.forward) {
        cam.* = cam.*.mul(za.Mat4.fromTranslate(za.Vec3.fromSlice(&[_]f32{ 0.0, 0.0, -deltaDist })));
    }
    if (state.back) {
        cam.* = cam.*.mul(za.Mat4.fromTranslate(za.Vec3.fromSlice(&[_]f32{ 0.0, 0.0, deltaDist })));
    }
    if (state.left) {
        cam.* = cam.*.mul(za.Mat4.fromTranslate(za.Vec3.fromSlice(&[_]f32{ -deltaDist, 0.0, 0.0 })));
    }
    if (state.right) {
        cam.* = cam.*.mul(za.Mat4.fromTranslate(za.Vec3.fromSlice(&[_]f32{ deltaDist, 0.0, 0.0 })));
    }
    if (state.up) {
        cam.* = cam.*.mul(za.Mat4.fromTranslate(za.Vec3.fromSlice(&[_]f32{ 0.0, deltaDist, 0.0 })));
    }
    if (state.down) {
        cam.* = cam.*.mul(za.Mat4.fromTranslate(za.Vec3.fromSlice(&[_]f32{ 0.0, -deltaDist, 0.0 })));
    }
}

pub fn main() !void {
    //init glfw
    if (!glfw.init(.{})) {
        return error.GlfwInitFailed;
    }
    defer glfw.terminate();

    if (!glfw.vulkanSupported()) {
        std.log.err("Vulkan is unsupported", .{});
        return error.NoVulkan;
    }

    //create window
    const window = glfw.Window.create(
        1600,
        900,
        "Vulkan Renderer",
        null,
        null,
        .{ .client_api = .no_api, .resizable = false, .samples = 4 },
    ) orelse return error.WindowInitFailed;
    defer window.destroy();

    //init vulkan
    var vkCtx = try vk.VulkanRenderer.init(window);
    defer vkCtx.deinit();

    //setup input
    var camState = CamState{};
    window.setUserPointer(&camState);
    window.setKeyCallback(glfwCallbackKeyPress);
    window.setMouseButtonCallback(glfwCallbackButton);
    window.setCursorPosCallback(glfwCallbackMotion);

    const posDelta = za.Vec3.set(0.0);
    _ = posDelta;

    var lastTime = glfw.getTime();
    while (!window.shouldClose()) {
        glfw.pollEvents();
        const currTime = glfw.getTime();
        const deltaTime = currTime - lastTime;
        lastTime = currTime;
        updateCamera(&camState, deltaTime);

        try vkCtx.draw(window, camState.cam);
        window.swapBuffers();
    }
}
