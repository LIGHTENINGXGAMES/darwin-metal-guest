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

The protocol inside each slot is UniXNU-qemu's `wire/QemuMetalWire.h`, unchanged. The darwin machine adds a register page with a
doorbell and a host-presence register; the kernel writes a slot record (`struct darwin_metal_slot_record`) at the start of each slot it
maps. Without a serving host the plugin returns nil and the process keeps the software renderer.

## Sources

| Directory | Origin | License |
| --- | --- | --- |
| `frontend/` | [UniXNU/AdrenoMetal](https://github.com/UniXNU/AdrenoMetal) 454ff2c, unchanged | MIT |
| `wire/`, `remote/` | [xVanTuring/UniXNU-qemu](https://github.com/xVanTuring/UniXNU-qemu) 97b75b1 `package/QemuMetal` | BSD-2-Clause-Patent |
| `plugin/` | adapted from UniXNU-qemu's `QemuMetalPlugin.mm` | BSD-2-Clause-Patent |
| `include/darwin_metal.h` | copy of the darwin machine's `qemu-sptm/include/hw/arm/darwin_metal.h` (interface constants and layouts) | as in that tree |
| `tools/`, `scripts/` | this repository | BSD-2-Clause-Patent |

The first commit holds the upstream files verbatim; later commits are the darwin adaptations:

- `remote/QemuMetalRemote.cpp`: rings the doorbell after each request; implements the two bridge entry points newer than UniXNU-qemu
  (`nmb_buffer_new_no_copy_releasing`, and `nmb_texture_new_on_surface`, which refuses planar surfaces for now).
- `plugin/DarwinMetalPlugin.mm`: maps the slot write-combined and the register page uncached, reads the kernel's slot record, and
  checks that a host serves the window before it opens a device.

## Build locally

On macOS with Xcode: `sh scripts/build.sh build`. `IOS_TARGET` overrides the target triple (default `arm64e-apple-ios17.0`).
