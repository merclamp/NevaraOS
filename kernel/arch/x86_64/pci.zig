//! PCI configuration space scanner — legacy I/O port mechanism.
//! Config address: 0xCF8, config data: 0xCFC.
//! Scans bus 0, devices 0-31, function 0 only (single-function devices).

const console = @import("console.zig");

pub const PciDevice = struct {
    bus: u8,
    dev: u8,
    func: u8,
    vendor: u16,
    device_id: u16,
    class: u8,
    subclass: u8,
    irq: u8,
    bar0: u32, // Base Address Register 0
};

// At most 32 devices on bus 0.
var devices: [32]PciDevice = undefined;
var device_count: usize = 0;

inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (value),
          [p] "{dx}" (port),
    );
}

inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[p], %[r]"
        : [r] "={eax}" (-> u32),
        : [p] "{dx}" (port),
    );
}

fn cfgAddr(bus: u8, dev: u8, func: u8, offset: u8) u32 {
    return (1 << 31) |
           (@as(u32, bus) << 16) |
           (@as(u32, dev) << 11) |
           (@as(u32, func) << 8) |
           (offset & 0xFC);
}

pub fn cfgRead32(bus: u8, dev: u8, func: u8, offset: u8) u32 {
    outl(0xCF8, cfgAddr(bus, dev, func, offset));
    return inl(0xCFC);
}

pub fn cfgWrite32(bus: u8, dev: u8, func: u8, offset: u8, value: u32) void {
    outl(0xCF8, cfgAddr(bus, dev, func, offset));
    outl(0xCFC, value);
}

pub fn cfgRead16(bus: u8, dev: u8, func: u8, offset: u8) u16 {
    const v = cfgRead32(bus, dev, func, offset & 0xFC);
    const shift: u5 = @intCast((offset & 2) * 8);
    return @truncate(v >> shift);
}

pub fn cfgWrite16(bus: u8, dev: u8, func: u8, offset: u8, value: u16) void {
    const full = cfgRead32(bus, dev, func, offset & 0xFC);
    const shift: u5 = @intCast((offset & 2) * 8);
    const mask: u32 = ~(@as(u32, 0xFFFF) << shift);
    cfgWrite32(bus, dev, func, offset & 0xFC, (full & mask) | (@as(u32, value) << shift));
}

pub fn cfgRead8(bus: u8, dev: u8, func: u8, offset: u8) u8 {
    const v = cfgRead32(bus, dev, func, offset & 0xFC);
    const shift: u5 = @intCast((offset & 3) * 8);
    return @truncate(v >> shift);
}

/// Scan PCI bus 0 for all devices and record them.
pub fn init() void {
    device_count = 0;
    var d: u8 = 0;
    while (d < 32) : (d += 1) {
        const v = cfgRead32(0, d, 0, 0);
        const vendor: u16 = @truncate(v);
        if (vendor == 0xFFFF) continue; // no device

        const device_id: u16 = @truncate(v >> 16);
        const class_info = cfgRead32(0, d, 0, 0x08);
        const class: u8   = @truncate(class_info >> 24);
        const subclass: u8 = @truncate(class_info >> 16);
        const irq = cfgRead8(0, d, 0, 0x3C);
        const bar0 = cfgRead32(0, d, 0, 0x10);

        if (device_count < devices.len) {
            devices[device_count] = .{
                .bus = 0, .dev = d, .func = 0,
                .vendor = vendor, .device_id = device_id,
                .class = class, .subclass = subclass,
                .irq = irq, .bar0 = bar0,
            };
            device_count += 1;
        }
    }
    console.writeString("[pci] scan: ");
    console.writeDec(device_count);
    console.writeString(" device(s) found\n");
}

/// Find a device by vendor:device pair. Returns null if not found.
pub fn find(vendor: u16, device_id: u16) ?*PciDevice {
    for (devices[0..device_count]) |*dev| {
        if (dev.vendor == vendor and dev.device_id == device_id) return dev;
    }
    return null;
}

/// Enable I/O space and bus mastering in the PCI command register.
pub fn enableIo(bus: u8, dev: u8, func: u8) void {
    const cmd = cfgRead16(bus, dev, func, 0x04);
    cfgWrite16(bus, dev, func, 0x04, cmd | 0x05); // bit0=I/O, bit2=bus master
}
