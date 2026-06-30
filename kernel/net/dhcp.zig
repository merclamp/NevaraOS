//! Minimal DHCP client (RFC 2131 happy path).
//!
//! Runs once at boot to obtain an IPv4 lease: DISCOVER → OFFER → REQUEST → ACK,
//! all broadcast over UDP 68→67. On success it installs the address, netmask,
//! router and DNS server via net.applyConfig(); on failure the stack keeps its
//! static defaults so the system still works.
//!
//! Replies are addressed to the not-yet-assigned offered IP (or to broadcast),
//! so net.accept_all is raised for the duration to let the receive path see them.

const net = @import("net.zig");
const rtl = @import("rtl8139.zig");
const console = @import("../arch/x86_64/console.zig");

const ZERO_IP:  [4]u8 = .{ 0, 0, 0, 0 };
const BCAST_IP: [4]u8 = .{ 255, 255, 255, 255 };
const BCAST_MAC: [6]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

// DHCP message types (option 53).
const DISCOVER: u8 = 1;
const OFFER: u8 = 2;
const REQUEST: u8 = 3;
const ACK: u8 = 5;

const MAGIC: [4]u8 = .{ 0x63, 0x82, 0x53, 0x63 };

const Lease = struct {
    yiaddr: [4]u8 = .{ 0, 0, 0, 0 },
    netmask: [4]u8 = .{ 255, 255, 255, 0 },
    router: [4]u8 = .{ 0, 0, 0, 0 },
    dns: [4]u8 = .{ 0, 0, 0, 0 },
    server_id: [4]u8 = .{ 0, 0, 0, 0 },
};

fn printIp(ip: [4]u8) void {
    for (ip, 0..) |o, i| {
        if (i != 0) console.writeString(".");
        console.writeDec(o);
    }
}

/// Fill the fixed 240-byte BOOTP header + magic cookie. Returns the option offset.
fn buildBootp(mac: [6]u8, xid: [4]u8, out: []u8) usize {
    @memset(out[0..240], 0);
    out[0] = 1; // op = BOOTREQUEST
    out[1] = 1; // htype = Ethernet
    out[2] = 6; // hlen
    @memcpy(out[4..8], &xid);
    out[10] = 0x80; // flags: broadcast (so the server broadcasts its reply)
    @memcpy(out[28..34], &mac); // chaddr
    @memcpy(out[236..240], &MAGIC);
    return 240;
}

fn addOpt(out: []u8, pos: usize, code: u8, val: []const u8) usize {
    out[pos] = code;
    out[pos + 1] = @intCast(val.len);
    @memcpy(out[pos + 2 .. pos + 2 + val.len], val);
    return pos + 2 + val.len;
}

/// Parse a BOOTREPLY. Returns the DHCP message type, or null if it isn't a
/// well-formed reply for our transaction.
fn parse(buf: []const u8, xid: [4]u8, lease: *Lease) ?u8 {
    if (buf.len < 240) return null;
    if (buf[0] != 2) return null; // op = BOOTREPLY
    if (!eql4(buf[4..8], &xid)) return null;
    if (buf[236] != MAGIC[0] or buf[237] != MAGIC[1] or
        buf[238] != MAGIC[2] or buf[239] != MAGIC[3]) return null;

    @memcpy(&lease.yiaddr, buf[16..20]);

    var msg_type: u8 = 0;
    var pos: usize = 240;
    while (pos + 1 < buf.len) {
        const code = buf[pos];
        if (code == 255) break; // end
        if (code == 0) { pos += 1; continue; } // pad
        const olen = buf[pos + 1];
        const vs = pos + 2;
        if (vs + olen > buf.len) break;
        const val = buf[vs .. vs + olen];
        switch (code) {
            53 => if (olen >= 1) { msg_type = val[0]; },
            1  => if (olen >= 4) @memcpy(&lease.netmask, val[0..4]),
            3  => if (olen >= 4) @memcpy(&lease.router, val[0..4]),
            6  => if (olen >= 4) @memcpy(&lease.dns, val[0..4]),
            54 => if (olen >= 4) @memcpy(&lease.server_id, val[0..4]),
            else => {},
        }
        pos = vs + olen;
    }
    return msg_type;
}

fn eql4(a: []const u8, b: []const u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

/// Poll for a reply of the desired message type for our xid. IRQs may be off at
/// boot, so spin on PIO RX (~5M iterations ≈ 1 s); allow ~3 s.
fn recvReply(xid: [4]u8, want: u8, lease: *Lease) bool {
    var rbuf: [600]u8 = undefined;
    var src_ip: [4]u8 = undefined;
    var sp: u16 = 0;
    var dp: u16 = 0;
    const iters: usize = 3000 * 5000;
    var i: usize = 0;
    while (i < iters) : (i += 100) {
        rtl.pollRx();
        const n = net.udpRecv(&rbuf, &src_ip, &sp, &dp);
        if (n == 0) continue;
        if (dp != 68) continue; // not a DHCP reply to our client port
        const mt = parse(rbuf[0..n], xid, lease) orelse continue;
        if (mt == want) return true;
    }
    return false;
}

/// Obtain a lease and install it. Returns true on success.
pub fn configure() bool {
    if (!rtl.isReady()) return false;
    const mac = rtl.macAddr();
    const xid: [4]u8 = .{ 'N', 'E', 'V', 'A' };

    net.accept_all = true;
    defer net.accept_all = false;

    var pkt: [300]u8 = undefined;

    // DISCOVER.
    var n = buildBootp(mac, xid, &pkt);
    n = addOpt(&pkt, n, 53, &.{DISCOVER});
    n = addOpt(&pkt, n, 55, &.{ 1, 3, 6 }); // request: subnet, router, DNS
    pkt[n] = 255;
    n += 1;
    net.sendUdpRaw(ZERO_IP, BCAST_IP, BCAST_MAC, 68, 67, pkt[0..n]);

    var lease = Lease{};
    if (!recvReply(xid, OFFER, &lease)) {
        console.writeString("[dhcp] no OFFER — keeping static config\n");
        return false;
    }
    console.writeString("[dhcp] OFFER ");
    printIp(lease.yiaddr);
    console.writeString("\n");

    // REQUEST the offered address.
    n = buildBootp(mac, xid, &pkt);
    n = addOpt(&pkt, n, 53, &.{REQUEST});
    n = addOpt(&pkt, n, 50, &lease.yiaddr); // requested IP
    n = addOpt(&pkt, n, 54, &lease.server_id); // server identifier
    n = addOpt(&pkt, n, 55, &.{ 1, 3, 6 });
    pkt[n] = 255;
    n += 1;
    net.sendUdpRaw(ZERO_IP, BCAST_IP, BCAST_MAC, 68, 67, pkt[0..n]);

    var ack = Lease{};
    if (!recvReply(xid, ACK, &ack)) {
        console.writeString("[dhcp] no ACK — keeping static config\n");
        return false;
    }

    net.applyConfig(ack.yiaddr, ack.netmask, ack.router, ack.dns);
    console.writeString("[dhcp] bound ");
    printIp(ack.yiaddr);
    console.writeString(" mask ");
    printIp(ack.netmask);
    console.writeString(" gw ");
    printIp(ack.router);
    console.writeString(" dns ");
    printIp(ack.dns);
    console.writeString("\n");
    return true;
}
