// guest-metal-check: what Metal's discovery sees in the guest.
//
//   guest-metal-check [--queue]
//
// Lists every IOAcceleratorES service with the plugin keys the discovery reads, then asks Metal for the default device and all
// devices. --queue also makes a command queue, which needs a host that executes requests (the handshake host refuses it).
// Exit status: 0 a device, 1 no accelerator service, 2 an accelerator but no device, 3 the queue was refused.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <mach/mach.h>

namespace {
NSString *property(void *iokit, mach_port_t service, NSString *key) {
    auto copy = (CFTypeRef (*)(mach_port_t, CFStringRef, CFAllocatorRef, uint32_t))dlsym(iokit, "IORegistryEntryCreateCFProperty");
    CFTypeRef value = copy ? copy(service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0) : nullptr;
    if (!value) return @"-";
    NSString *text = CFGetTypeID(value) == CFStringGetTypeID() ? [(__bridge NSString *)value copy] : [(__bridge id)value description];
    CFRelease(value);
    return text;
}

unsigned listAccelerators() {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
    auto matching = iokit ? (CFMutableDictionaryRef (*)(const char *))dlsym(iokit, "IOServiceMatching") : nullptr;
    auto services = iokit ? (kern_return_t (*)(mach_port_t, CFDictionaryRef, mach_port_t *))dlsym(iokit, "IOServiceGetMatchingServices")
                          : nullptr;
    auto next = iokit ? (mach_port_t (*)(mach_port_t))dlsym(iokit, "IOIteratorNext") : nullptr;
    auto className = iokit ? (kern_return_t (*)(mach_port_t, char *))dlsym(iokit, "IOObjectGetClass") : nullptr;
    auto release = iokit ? (kern_return_t (*)(mach_port_t))dlsym(iokit, "IOObjectRelease") : nullptr;
    if (!matching || !services || !next || !className || !release) {
        printf("IOKit: not available\n");
        return 0;
    }
    mach_port_t iterator = MACH_PORT_NULL;
    if (services(0, matching("IOAcceleratorES"), &iterator) != KERN_SUCCESS) return 0;
    unsigned count = 0;
    while (mach_port_t service = next(iterator)) {
        char name[128] = {};
        className(service, name);
        printf("accelerator %s: MetalPluginName=%s MetalPluginClassName=%s\n", name,
               property(iokit, service, @"MetalPluginName").UTF8String, property(iokit, service, @"MetalPluginClassName").UTF8String);
        release(service);
        count++;
    }
    release(iterator);
    return count;
}
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const bool queue = argc > 1 && !strcmp(argv[1], "--queue");
        const unsigned accelerators = listAccelerators();
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
        printf("default device: %s (registry %llx)\n", device ? device.name.UTF8String : "none",
               device ? (unsigned long long)device.registryID : 0ull);
        printf("all devices: %lu\n", (unsigned long)all.count);
        if (!device) return accelerators ? 2 : 1;
        if (queue) {
            id<MTLCommandQueue> made = [device newCommandQueue];
            printf("command queue: %s\n", made ? "made" : "refused");
            if (!made) return 3;
        }
        return 0;
    }
}
