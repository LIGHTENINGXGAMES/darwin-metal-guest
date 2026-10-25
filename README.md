# darwin-metal-guest

Guest side of the darwin QEMU machine's Metal forwarding device, for iOS 27 (24A437, arm64e). The GitHub workflow builds it with
Xcode's iOS SDK and uploads:

- `QemuMetal.bundle`: the Metal plugin Metal's discovery loads from `/System/Library/Extensions` for the kernel's accelerator
  (`MetalPluginName=QemuMetal`, `MetalPluginClassName=QemuMetalDevice`).
- `guest-metal-check`: lists `IOAcceleratorES` services and asks Metal for its devices.
- `cdhashes.json`: the CDHashes to add to the guest's trust cache. Both are ad hoc signed with 4 KiB pages.

No Apple binaries are in this repository or the artifact.

## How it fits

```
backboardd -> Metal discovery -> QemuMetal.bundle (plugin/DarwinMetalPlugin.mm)
           -> NativeMetal frontend (frontend/) -> remote bridge (remote/QemuMetalRemote.cpp)
           -> window slot + doorbell (kernel accelerator, include/darwin_metal.h)
           -> QEMU darwin machine (metal-window) -> darwin-metal-host on the Windows host
```

The protocol inside each slot retains UniXNU-qemu's base `wire/QemuMetalWire.h` layouts, with an optional Darwin display extension below. The darwin machine adds a register page with a
doorbell and a host-presence register; the kernel writes a slot record (`struct darwin_metal_slot_record`) at the start of each slot it
maps. The slot uses Copyback (Normal memory); WriteCombine outside DRAM becomes Device memory on arm64 and cannot serve the bridge's
unaligned SIMD accesses. The appended kernel/host lease protects slot reuse during host writeback. Without a serving host the plugin
returns nil and the process keeps the software renderer.

## Sources

| Directory | Origin | License |
| --- | --- | --- |
| `frontend/` | adapted from [UniXNU/AdrenoMetal](https://github.com/UniXNU/AdrenoMetal) 454ff2c | MIT |
| `wire/`, `remote/` | [xVanTuring/UniXNU-qemu](https://github.com/xVanTuring/UniXNU-qemu) 97b75b1 `package/QemuMetal` | BSD-2-Clause-Patent |
| `plugin/` | adapted from UniXNU-qemu's `QemuMetalPlugin.mm` | BSD-2-Clause-Patent |
| `include/darwin_metal.h` | copy of the darwin machine's `qemu-sptm/include/hw/arm/darwin_metal.h` (interface constants and layouts) | as in that tree |
| `tools/`, `scripts/` | this repository | BSD-2-Clause-Patent |

The first commit holds the upstream files verbatim; later commits are the darwin adaptations:

- `remote/QemuMetalRemote.cpp`: rings the doorbell after each request; implements the two bridge entry points newer than UniXNU-qemu
  (`nmb_buffer_new_no_copy_releasing`, and `nmb_texture_new_on_surface`, which refuses planar surfaces for now).
- `plugin/DarwinMetalPlugin.mm`: maps the slot copyback and the register page uncached, reads the kernel's slot record, and
  checks that a host serves the window before it opens a device.
- The dynamic device subclass uses the current OS's runtime layout without reading private base ivars. Family and unified-memory
  queries come from the host, and reported shared memory is bounded by the slot heap.
- `guest-metal-check` is signed with only the `AGXDeviceUserClient` class entitlement required by the native IOKit sandbox.

## Build locally

On macOS with Xcode: `sh scripts/build.sh build`. `IOS_TARGET` overrides the target triple (default `arm64e-apple-ios18.0`).

## Optional host display surfaces

An extended host may append an eight-byte `QMDeviceFeatures` to the 136-byte `QMDeviceInfo`
in `QM_OPEN`'s reply. Without bit 0 (`QM_FEATURE_DISPLAY_SURFACE`), every import keeps the
existing shadow/copyback path. Other optional bits are ignored.

For a nonplanar `RGhA` IOSurface's plane 0, Texture2D RGBA16Float 1080×2400 with one depth,
level, sample and array element, a negotiated host receives `QM_DISPLAY_SURFACE` (4096).
Its 120-byte payload is the original 80-byte descriptor followed by shadow offset, row
stride, reserved allocation length from that offset, IOSurfaceID and plane (five u64s).
The returned texture descriptor keeps the original reply layout. The host owns the live
GPU pixels and associates imports of the same IOSurfaceID; the framebuffer selects the
image for presentation independently through SwapEnd.

A new display import copies its initial CPU bytes into the reserved shadow once; the host
uploads them only when creating that global IOSurfaceID's first live GPU image. Later
imports of that identity must preserve its newer GPU contents. A successful display import
skips routine shadow copy-in/copy-out and the frontend's CPU
surface cache flush. Views retain the import as before, and command buffers still wait for
GPU completion before returning from a commit that writes imported memory. Explicit texture
`getBytes` and `replaceRegion` continue through their staging requests; these never copy a
display import's stale shadow over its IOSurface. A negotiated candidate that fails creation
is refused rather than silently changing storage models.

This opt-in path covers GPU display targets, not arbitrary CPU-owned IOSurfaces. A live
import cannot mix a display image with ordinary shadow texture or raw-buffer aliases:
`buffer.contents`, `gpuAddress`, buffer bindings and buffer blits are refused for display
imports, and an import whose raw storage was already exposed cannot become a display image.
Direct IOSurface CPU access outside this plugin (`IOSurfaceLock`/`IOSurfaceGetBaseAddress`)
is not intercepted or made coherent by this extension after the initial upload. Other dimensions, formats,
planes and texture shapes keep the existing behavior. Full guest acceptance requires the
matching host and framebuffer, a macOS/Xcode build, and an actual system run.
