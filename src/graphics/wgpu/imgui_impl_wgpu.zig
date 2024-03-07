const c = @import("../../c.zig");

pub extern fn ImGui_ImplWGPU_Init(device: c.WGPUDevice, num_frames_in_flight: c_int, rt_format: c.WGPUTextureFormat, depth_format: c.WGPUTextureFormat) callconv(.C) bool;
pub extern fn ImGui_ImplWGPU_Shutdown() callconv(.C) void;
pub extern fn ImGui_ImplWGPU_NewFrame() callconv(.C) void;
pub extern fn ImGui_ImplWGPU_RenderDrawData(draw_data: *c.ImDrawData, pass_encoder: c.WGPURenderPassEncoder) callconv(.C) void;

// Use if you want to reset your rendering device without losing Dear ImGui state.
pub extern fn ImGui_ImplWGPU_InvalidateDeviceObjects() callconv(.C) void;
pub extern fn ImGui_ImplWGPU_CreateDeviceObjects() callconv(.C) bool;
