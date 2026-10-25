#ifndef HW_ARM_DARWIN_METAL_H
#define HW_ARM_DARWIN_METAL_H

#include <stdint.h>

/*
 * Opt-in Metal forwarding transport (machine property metal-window). The guest
 * sees a private register page and a window of memory outside DRAM. A host
 * process maps the same window and serves UniXNU-qemu's QemuMetalWire protocol
 * in it; QEMU only carries the doorbell and the answer interrupt.
 *
 * The kernel finds both apertures at these fixed addresses, like the boot
 * framebuffer's (darwin_display.h), and checks the ID register first.
 */
#define DARWIN_METAL_CONTROL_BASE UINT64_C(0xfffc000000)
#define DARWIN_METAL_WINDOW_BASE UINT64_C(0xfe00000000)
#define DARWIN_METAL_WINDOW_MAX UINT64_C(0x100000000)

enum {
    DARWIN_METAL_CONTROL_BYTES = 0x4000,
    DARWIN_METAL_CONTROL_ID = 0x4c544d51,     /* "QMTL", QemuMetalWire.h QM_MAGIC */
    DARWIN_METAL_CONTROL_VERSION = 1,
    DARWIN_METAL_WINDOW_UNIT_MIB = 64,        /* size granule and minimum */
    DARWIN_METAL_SLOTS = 9,                   /* QemuMetalWire.h QM_SLOTS */
    DARWIN_METAL_NO_IRQ = 0xffffffff,

    /* 32-bit registers. */
    DARWIN_METAL_ID_REGISTER = 0x00,          /* r: DARWIN_METAL_CONTROL_ID */
    DARWIN_METAL_VERSION_REGISTER = 0x04,     /* r: DARWIN_METAL_CONTROL_VERSION */
    DARWIN_METAL_WINDOW_LO_REGISTER = 0x08,   /* r: window guest physical base */
    DARWIN_METAL_WINDOW_HI_REGISTER = 0x0c,
    DARWIN_METAL_SIZE_LO_REGISTER = 0x10,     /* r: window bytes */
    DARWIN_METAL_SIZE_HI_REGISTER = 0x14,
    DARWIN_METAL_IRQ_NUMBER_REGISTER = 0x18,  /* r: AIC line, or DARWIN_METAL_NO_IRQ */
    DARWIN_METAL_HOST_REGISTER = 0x1c,        /* r: enum darwin_metal_host */
    DARWIN_METAL_DOORBELL_REGISTER = 0x20,    /* w: slot whose request is ready */
    DARWIN_METAL_IRQ_STATUS_REGISTER = 0x24,  /* r: slots the host answered; w: 1 clears */
    DARWIN_METAL_IRQ_ENABLE_REGISTER = 0x28,  /* rw: answered slots that raise the line */
};

enum darwin_metal_host {
    DARWIN_METAL_HOST_ABSENT,
    DARWIN_METAL_HOST_SERVING,
};

/*
 * The kernel writes this at the start of a slot when it maps the slot to a
 * process (QemuMetalWire.h places its control block at 64 KiB). The process
 * rings the doorbell with its slot number after each request.
 */
#define DARWIN_METAL_SLOT_MAGIC UINT32_C(0x4c534d51) /* "QMSL" */
/* Kernel/host lease extension. The original 32 bytes and QemuMetalWire are unchanged. */
#define DARWIN_METAL_LEASE_BUSY UINT64_C(1)
#define DARWIN_METAL_LEASE_RETIRED UINT64_C(2)
#define DARWIN_METAL_LEASE_STEP UINT64_C(4)
struct darwin_metal_slot_record {
    uint32_t magic, slot;
    uint64_t offset, bytes;      /* the slot within the window */
    uint64_t window_bytes;
    uint64_t lease;
};

/*
 * Between QEMU and the host process only; the guest never sees it. QEMU creates
 * the Windows objects Local\<metal-name>.window (the window's bytes),
 * .transport (this block), .doorbell and .irq (auto-reset events); the host
 * opens them. Slot masks use bit N for slot N.
 */
#define DARWIN_METAL_TRANSPORT_MAGIC UINT32_C(0x50544d51) /* "QMTP" */
enum {
    DARWIN_METAL_TRANSPORT_VERSION = 1,
    DARWIN_METAL_TRANSPORT_BYTES = 0x1000,
};

struct darwin_metal_transport {
    uint32_t magic, version;     /* QEMU, magic written last */
    uint64_t window_base;        /* QEMU: guest physical, for the host's log */
    uint64_t window_bytes;       /* QEMU */
    uint64_t qemu_pid;           /* QEMU */
    uint64_t generation;         /* QEMU: one more per machine reset; the host drops every session */
    uint64_t doorbells;          /* QEMU ORs rung slots; the host takes them by exchange */
    uint64_t doorbell_count;     /* QEMU */
    uint64_t answered;           /* host ORs answered slots, then sets .irq; QEMU takes them by exchange */
    uint64_t host_pid;           /* host: nonzero while it serves */
    uint64_t host_beat;          /* host: counts up while it serves */
};

#ifdef QEMU_OSDEP_H
/* The darwin machine's side; irq may be NULL (no dtree arm-io/qemu-metal node). */
typedef struct DarwinMetal DarwinMetal;
DarwinMetal *darwin_metal_create(Object *owner, const char *name,
                                 uint64_t window_bytes, qemu_irq irq,
                                 uint32_t irq_number, Error **errp);
void darwin_metal_reset(DarwinMetal *metal);
#endif

#endif
