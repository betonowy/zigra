pub usingnamespace @cImport({
    @cInclude("vk_mem_alloc.h");
});

const c = @cImport({
    @cInclude("vk_mem_alloc.h");
});

fn createAllocator() !*c.VmaAllocator {
    var allocator: *c.VmaAllocator = undefined;

    const create_info = c.VmaAllocatorCreateInfo{};

    if (c.vmaCreateAllocator(create_info, &allocator) != c.VK_SUCCESS) {
        return error.InitializationFailed;
    }

    return allocator;
}

fn destroyAllocator(allocator: *c.VmaAllocator) void {
    c.vmaDestroyAllocator(allocator);
}
