const std = @import("std");
const c = @import("c_imports.zig");
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

fn glfwCallbackKeyPress(window: ?*c.GLFWwindow, key: c_int, scanCode: c_int, action: c_int, _: c_int) callconv(.C) void {
    const state: *CamState = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));
    _ = scanCode;
    const isReleased = (action == c.GLFW_RELEASE);
    switch (key) {
        c.GLFW_KEY_W => {
            state.forward = !isReleased;
        },
        c.GLFW_KEY_S => {
            state.back = !isReleased;
        },
        c.GLFW_KEY_A => {
            state.left = !isReleased;
        },
        c.GLFW_KEY_D => {
            state.right = !isReleased;
        },
        c.GLFW_KEY_E => {
            state.up = !isReleased;
        },
        c.GLFW_KEY_Q => {
            state.down = !isReleased;
        },
        else => {},
    }
}

fn glfwCallbackButton(window: ?*c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.C) void {
    const state: *CamState = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));
    if (button == c.GLFW_MOUSE_BUTTON_RIGHT and action == c.GLFW_PRESS) {
        state.mousing = !state.mousing;
        if (state.mousing) {
            c.glfwSetInputMode(window, c.GLFW_CURSOR, c.GLFW_CURSOR_DISABLED);
        } else {
            c.glfwSetInputMode(window, c.GLFW_CURSOR, c.GLFW_CURSOR_NORMAL);
        }
    }
}

fn glfwCallbackMotion(window: ?*c.GLFWwindow, x: f64, y: f64) callconv(.C) void {
    const state: *CamState = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));
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
    if (c.glfwInit() != c.GLFW_TRUE) {
        return error.GlfwInitFailed;
    }

    if (c.glfwVulkanSupported() != c.GLFW_TRUE) {
        std.log.err("Vulkan is unsupported", .{});
        return error.NoVulkan;
    }

    //create window
    const extent = c.VkExtent2D{ .width = 1600, .height = 900 };
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);
    c.glfwWindowHint(c.GLFW_DECORATED, c.GLFW_FALSE);
    c.glfwWindowHint(c.GLFW_SAMPLES, 4);
    const window = c.glfwCreateWindow(
        @intCast(extent.width),
        @intCast(extent.height),
        "Vulkan Renderer",
        null,
        null,
    ) orelse return error.WindowInitFailed;
    defer c.glfwDestroyWindow(window);

    //init vulkan
    var vkCtx = try vk.VulkanRenderer.init(window);
    defer vkCtx.deinit();

    //setup input
    var camState = CamState{};
    c.glfwSetWindowUserPointer(window, &camState);
    _ = c.glfwSetKeyCallback(window, glfwCallbackKeyPress);
    _ = c.glfwSetMouseButtonCallback(window, glfwCallbackButton);
    _ = c.glfwSetCursorPosCallback(window, glfwCallbackMotion);

    const posDelta = za.Vec3.set(0.0);
    _ = posDelta;

    var lastTime = c.glfwGetTime();
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        c.glfwPollEvents();
        const currTime = c.glfwGetTime();
        const deltaTime = currTime - lastTime;
        lastTime = currTime;
        updateCamera(&camState, deltaTime);

        try vkCtx.draw(window, camState.cam);
        c.glfwSwapBuffers(window);
    }
}
