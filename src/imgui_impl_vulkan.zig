const std = @import("std");
const c = @import("c.zig");
const vk = @import("vulkan");

pub const ImGui_ImplVulkanH_Frame = extern struct {
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,
    backbuffer: vk.Image,
    backbuffer_view: vk.ImageView,
    framebuffer: vk.Framebuffer,
};

pub const ImGui_ImplVulkanH_FrameSemaphores = extern struct {
    image_acquired_semaphore: vk.Semaphore,
    render_complete_semaphore: vk.Semaphore,
};

pub const ImGui_ImplVulkanH_Window = extern struct {
    width: c_int,
    height: c_int,
    swapchain: vk.SwapchainKHR,
    surface: vk.SurfaceKHR,
    surface_format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    use_dynamic_rendering: bool,
    clear_enable: bool,
    clear_value: vk.ClearValue,
    frame_index: u32,
    image_count: u32,
    semaphore_index: u32,
    frames: [*]ImGui_ImplVulkanH_Frame,
    frame_semaphores: [*]ImGui_ImplVulkanH_FrameSemaphores,
};

pub const ImGui_ImplVulkan_InitInfo = extern struct {
    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    queue_family: u32,
    queue: vk.Queue,
    pipeline_cache: vk.PipelineCache,
    descriptor_pool: vk.DescriptorPool,
    subpass: u32,
    min_image_count: u32,
    image_count: u32,
    msaa_samples: vk.SampleCountFlags,
    use_dynamic_rendering: bool,
    color_attachment_format: vk.Format,
    allocator: ?*const vk.AllocationCallbacks = null,
    check_vk_result_fn: ?*const fn (vk.Result) callconv(.C) void = null,
    min_allocation_size: vk.DeviceSize,
};

pub extern fn ImGui_ImplVulkan_Init(info: *ImGui_ImplVulkan_InitInfo, render_pass: vk.RenderPass) bool;
pub extern fn ImGui_ImplVulkan_Shutdown() void;
pub extern fn ImGui_ImplVulkan_NewFrame() void;
pub extern fn ImGui_ImplVulkan_RenderDrawData(draw_data: *c.ImDrawData, command_buffer: vk.CommandBuffer, pipeline: vk.Pipeline) void;
pub extern fn ImGui_ImplVulkan_CreateFontsTexture() bool;
pub extern fn ImGui_ImplVulkan_DestroyFontsTexture() void;
pub extern fn ImGui_ImplVulkan_SetMinImageCount(min_image_count: u32) void;
pub extern fn ImGui_ImplVulkan_AddTexture(sampler: vk.Sampler, image_view: vk.ImageView, image_layout: vk.ImageLayout) vk.DescriptorSet;
pub extern fn ImGui_ImplVulkan_RemoveTexture(descriptor_set: vk.DescriptorSet) void;
pub extern fn ImGui_ImplVulkan_LoadFunctions(
    loader_func: ?*const fn (function_name: [*:0]const u8, user_data: ?*anyopaque) callconv(vk.vulkan_call_conv) void,
    user_data: ?*anyopaque,
) bool;
pub extern fn ImGui_ImplVulkanH_CreateOrResizeWindow(
    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    wnd: *ImGui_ImplVulkanH_Window,
    queue_family: u32,
    allocator: *const vk.AllocationCallbacks,
    w: c_int,
    h: c_int,
    min_image_count: u32,
) void;
pub extern fn ImGui_ImplVulkanH_DestroyWindow(instance: vk.Instance, device: vk.Device, wnd: *ImGui_ImplVulkanH_Window, allocator: *const vk.AllocationCallbacks) void;
pub extern fn ImGui_ImplVulkanH_SelectSurfaceFormat(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR, request_formats: [*]const vk.Format, request_formats_count: c_int, request_color_space: vk.ColorSpaceKHR) vk.SurfaceFormatKHR;
pub extern fn ImGui_ImplVulkanH_SelectPresentMode(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR, request_modes: [*]const vk.PresentModeKHR, request_modes_count: c_int) vk.PresentModeKHR;
pub extern fn ImGui_ImplVulkanH_GetMinImageCountFromPresentMode(present_mode: vk.PresentModeKHR) c_int;
