//! Nevara network stack — Ethernet / ARP / IPv4 / ICMP / UDP.
//!
//! Configuration (QEMU user-mode networking defaults):
//!   Our IP:  10.0.2.15
//!   Gateway: 10.0.2.2  (QEMU SLIRP gateway)
//!   Netmask: 255.255.255.0
//!   DNS:     10.0.2.3
//!
//! Implemented: ARP request/reply, ICMP echo reply, UDP send.
//! Not implemented: TCP, DHCP, IP fragmentation, routing (only same-subnet
//! and default-gateway send via gateway MAC).

const rtl = @import("rtl8139.zig");
const console = @import("../arch/x86_64/console.zig");
const heap = @import("../mm/heap.zig");
const pit = @import("../arch/x86_64/pit.zig");

// ---- Config ----------------------------------------------------------------

pub const MY_IP:  [4]u8 = .{ 10, 0, 2, 15 };
pub const GW_IP:  [4]u8 = .{ 10, 0, 2,  2 };
pub const NETMASK:[4]u8 = .{ 255, 255, 255, 0 };

const BROADCAST_MAC: [6]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
const ZERO_MAC:      [6]u8 = .{ 0, 0, 0, 0, 0, 0 };

var my_mac: [6]u8 = .{0} ** 6;

// ---- ARP cache -------------------------------------------------------------

const ARP_CACHE_SIZE = 8;
const ArpEntry = struct {
    ip: [4]u8 = .{0,0,0,0},
    mac: [6]u8 = .{0,0,0,0,0,0},
    valid: bool = false,
};
var arp_cache: [ARP_CACHE_SIZE]ArpEntry = .{ArpEntry{}} ** ARP_CACHE_SIZE;

fn arpCacheLookup(ip: [4]u8) ?[6]u8 {
    for (&arp_cache) |*e| {
        if (e.valid and @as(u32, @bitCast(e.ip)) == @as(u32, @bitCast(ip))) return e.mac;
    }
    return null;
}

fn arpCacheStore(ip: [4]u8, mac: [6]u8) void {
    // Find existing or empty slot.
    for (&arp_cache) |*e| {
        if (!e.valid or @as(u32, @bitCast(e.ip)) == @as(u32, @bitCast(ip))) {
            e.* = .{ .ip = ip, .mac = mac, .valid = true };
            return;
        }
    }
    // Evict slot 0 (LRU not tracked, simple wraparound).
    arp_cache[0] = .{ .ip = ip, .mac = mac, .valid = true };
}

// ---- Packet buffer ---------------------------------------------------------

// Fixed-size scratch buffer for outgoing packets.
const MAX_FRAME = 1518;
var tx_frame: [MAX_FRAME]u8 = undefined;

fn writeU16be(buf: []u8, off: usize, v: u16) void {
    buf[off]     = @intCast(v >> 8);
    buf[off + 1] = @intCast(v & 0xFF);
}
fn writeU32be(buf: []u8, off: usize, v: u32) void {
    buf[off]     = @intCast(v >> 24);
    buf[off + 1] = @intCast((v >> 16) & 0xFF);
    buf[off + 2] = @intCast((v >>  8) & 0xFF);
    buf[off + 3] = @intCast(v & 0xFF);
}
fn readU16be(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | buf[off + 1];
}
fn readU32be(buf: []const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) | (@as(u32, buf[off+1]) << 16) |
           (@as(u32, buf[off+2]) << 8) | buf[off+3];
}

// ---- Ethernet frame --------------------------------------------------------
// [dst_mac 6][src_mac 6][ethertype 2][payload ...]

const ETH_ARP:  u16 = 0x0806;
const ETH_IPV4: u16 = 0x0800;
const ETH_HDR:  usize = 14;

fn buildEthHdr(dst: [6]u8, etype: u16, payload_len: usize) []u8 {
    @memcpy(tx_frame[0..6], &dst);
    @memcpy(tx_frame[6..12], &my_mac);
    writeU16be(&tx_frame, 12, etype);
    return tx_frame[0 .. ETH_HDR + payload_len];
}

// ---- ARP -------------------------------------------------------------------
// [htype 2][ptype 2][hlen 1][plen 1][op 2]
// [sha 6][spa 4][tha 6][tpa 4]   = 28 bytes

const ARP_REQUEST: u16 = 1;
const ARP_REPLY:   u16 = 2;
const ARP_LEN: usize = 28;

fn sendArpRequest(target_ip: [4]u8) void {
    const frame = buildEthHdr(BROADCAST_MAC, ETH_ARP, ARP_LEN);
    const p = ETH_HDR;
    writeU16be(&tx_frame, p,     0x0001); // HTYPE=Ethernet
    writeU16be(&tx_frame, p + 2, 0x0800); // PTYPE=IPv4
    tx_frame[p + 4] = 6; // HLEN
    tx_frame[p + 5] = 4; // PLEN
    writeU16be(&tx_frame, p + 6, ARP_REQUEST);
    @memcpy(tx_frame[p+8  .. p+14], &my_mac);
    @memcpy(tx_frame[p+14 .. p+18], &MY_IP);
    @memset(tx_frame[p+18 .. p+24], 0); // target MAC unknown
    @memcpy(tx_frame[p+24 .. p+28], &target_ip);
    rtl.sendFrame(frame);
}

fn handleArp(data: []const u8) void {
    if (data.len < ETH_HDR + ARP_LEN) return;
    const p = ETH_HDR;
    const op = readU16be(data, p + 6);
    const spa = data[p+14 .. p+18];
    const sha = data[p+8  .. p+14];
    const tpa = data[p+24 .. p+28];

    // Learn sender MAC.
    var spa4: [4]u8 = undefined;
    @memcpy(&spa4, spa);
    var sha6: [6]u8 = undefined;
    @memcpy(&sha6, sha);
    arpCacheStore(spa4, sha6);

    // Reply to ARP requests targeting our IP.
    if (op == ARP_REQUEST) {
        var tpa4: [4]u8 = undefined;
        @memcpy(&tpa4, tpa);
        if (@as(u32, @bitCast(tpa4)) != @as(u32, @bitCast(MY_IP))) return;

        // Build ARP reply.
        const frame = buildEthHdr(sha6, ETH_ARP, ARP_LEN);
        const r = ETH_HDR;
        writeU16be(&tx_frame, r,     0x0001);
        writeU16be(&tx_frame, r + 2, 0x0800);
        tx_frame[r + 4] = 6;
        tx_frame[r + 5] = 4;
        writeU16be(&tx_frame, r + 6, ARP_REPLY);
        @memcpy(tx_frame[r+8  .. r+14], &my_mac);
        @memcpy(tx_frame[r+14 .. r+18], &MY_IP);
        @memcpy(tx_frame[r+18 .. r+24], sha);
        @memcpy(tx_frame[r+24 .. r+28], spa);
        rtl.sendFrame(frame);
    }
}

// ---- IPv4 ------------------------------------------------------------------
// [ver_ihl 1][dscp 1][total_len 2][id 2][flags_frag 2][ttl 1][proto 1]
// [checksum 2][src 4][dst 4] = 20 bytes

const IPV4_HDR: usize = 20;
const PROTO_ICMP: u8 = 1;
const PROTO_UDP:  u8 = 17;

fn ipChecksum(buf: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 2) {
        sum += (@as(u32, buf[i]) << 8) | buf[i + 1];
    }
    if (i < buf.len) sum += @as(u32, buf[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

var ip_id: u16 = 0x1234;

fn buildIpHdr(dst_ip: [4]u8, proto: u8, payload_len: usize) void {
    const total = IPV4_HDR + payload_len;
    const p = ETH_HDR;
    tx_frame[p + 0] = 0x45; // version=4, IHL=5
    tx_frame[p + 1] = 0;
    writeU16be(&tx_frame, p + 2, @intCast(total));
    writeU16be(&tx_frame, p + 4, ip_id);
    ip_id +%= 1;
    writeU16be(&tx_frame, p + 6, 0x4000); // DF flag set
    tx_frame[p + 8]  = 64;    // TTL
    tx_frame[p + 9]  = proto;
    writeU16be(&tx_frame, p + 10, 0); // checksum (filled below)
    @memcpy(tx_frame[p+12 .. p+16], &MY_IP);
    @memcpy(tx_frame[p+16 .. p+20], &dst_ip);
    const csum = ipChecksum(tx_frame[p .. p + IPV4_HDR]);
    writeU16be(&tx_frame, p + 10, csum);
}

// ---- ICMP ------------------------------------------------------------------
// [type 1][code 1][checksum 2][id 2][seq 2][data...]

const ICMP_ECHO_REQUEST: u8 = 8;
const ICMP_ECHO_REPLY:   u8 = 0;
const ICMP_HDR: usize = 8;

fn handleIcmp(src_ip: [4]u8, src_mac: [6]u8, data: []const u8) void {
    const base = ETH_HDR + IPV4_HDR;
    if (data.len < base + ICMP_HDR) return;
    if (data[base] != ICMP_ECHO_REQUEST) return;

    // Echo reply: copy the original payload back.
    const icmp_start = base;
    const icmp_len = data.len - icmp_start;

    const frame = buildEthHdr(src_mac, ETH_IPV4, IPV4_HDR + icmp_len);
    _ = frame;
    buildIpHdr(src_ip, PROTO_ICMP, icmp_len);

    const r = ETH_HDR + IPV4_HDR;
    @memcpy(tx_frame[r .. r + icmp_len], data[icmp_start .. icmp_start + icmp_len]);
    tx_frame[r] = ICMP_ECHO_REPLY;
    tx_frame[r + 1] = 0;
    writeU16be(&tx_frame, r + 2, 0); // clear checksum before computing
    const csum = ipChecksum(tx_frame[r .. r + icmp_len]);
    writeU16be(&tx_frame, r + 2, csum);

    rtl.sendFrame(tx_frame[0 .. ETH_HDR + IPV4_HDR + icmp_len]);
}

// ---- UDP -------------------------------------------------------------------
// [src_port 2][dst_port 2][length 2][checksum 2][data...]

const UDP_HDR: usize = 8;

// Incoming UDP packet receive queue (ring, lock-free for single-producer/consumer).
const UDP_QUEUE_CAP = 8;
const UDP_PKT_MAX   = 1024;

pub const UdpPacket = struct {
    src_ip:   [4]u8,
    src_port: u16,
    dst_port: u16,
    len:      usize,
    data:     [UDP_PKT_MAX]u8,
};

var udp_queue: [UDP_QUEUE_CAP]UdpPacket = undefined;
var udp_head: usize = 0; // producer writes here
var udp_tail: usize = 0; // consumer reads from here

pub fn udpRecv(buf: []u8, src_ip: *[4]u8, src_port: *u16, dst_port: *u16) usize {
    if (udp_head == udp_tail) return 0;
    const pkt = &udp_queue[udp_tail % UDP_QUEUE_CAP];
    const n = @min(pkt.len, buf.len);
    @memcpy(buf[0..n], pkt.data[0..n]);
    src_ip.* = pkt.src_ip;
    src_port.* = pkt.src_port;
    dst_port.* = pkt.dst_port;
    udp_tail +%= 1;
    return n;
}

fn handleUdp(src_ip: [4]u8, data: []const u8) void {
    const base = ETH_HDR + IPV4_HDR;
    if (data.len < base + UDP_HDR) return;
    const sp = readU16be(data, base);
    const dp = readU16be(data, base + 2);
    const udp_len = readU16be(data, base + 4);
    const payload_len = if (udp_len > UDP_HDR) udp_len - UDP_HDR else 0;
    const payload_off = base + UDP_HDR;
    const actual = @min(payload_len, data.len - payload_off);

    if (udp_head - udp_tail < UDP_QUEUE_CAP) {
        const slot = &udp_queue[udp_head % UDP_QUEUE_CAP];
        slot.src_ip   = src_ip;
        slot.src_port = sp;
        slot.dst_port = dp;
        slot.len = actual;
        @memcpy(slot.data[0..actual], data[payload_off .. payload_off + actual]);
        udp_head +%= 1;
    }
}

/// Send a UDP datagram to dst_ip:dst_port from src_port.
pub fn udpSend(dst_ip: [4]u8, src_port: u16, dst_port: u16, payload: []const u8) void {
    if (!rtl.isReady()) return;
    const payload_len = @min(payload.len, UDP_PKT_MAX);
    const udp_total   = UDP_HDR + payload_len;
    const ip_total    = IPV4_HDR + udp_total;
    _ = ip_total;

    // Resolve destination MAC (gateway if not on-subnet).
    const dst_mac = resolveMac(dst_ip) orelse {
        console.writeString("[net] udpSend: no ARP entry for dst\n");
        return;
    };

    const frame = buildEthHdr(dst_mac, ETH_IPV4, IPV4_HDR + udp_total);
    _ = frame;
    buildIpHdr(dst_ip, PROTO_UDP, udp_total);

    const r = ETH_HDR + IPV4_HDR;
    writeU16be(&tx_frame, r,     src_port);
    writeU16be(&tx_frame, r + 2, dst_port);
    writeU16be(&tx_frame, r + 4, @intCast(udp_total));
    writeU16be(&tx_frame, r + 6, 0); // checksum optional for UDP
    @memcpy(tx_frame[r + UDP_HDR .. r + UDP_HDR + payload_len], payload[0..payload_len]);

    rtl.sendFrame(tx_frame[0 .. ETH_HDR + IPV4_HDR + udp_total]);
}

// ---- ICMP ping (send echo request, wait for reply) -------------------------

pub const PingResult = enum { ok, timeout, unreachable_no_arp };

var ping_reply_received: bool = false;
var ping_seq: u16 = 0;

/// Send an ICMP echo request to dst_ip and wait up to timeout_ms.
/// Returns .ok if a reply arrives, .timeout otherwise.
pub fn ping(dst_ip: [4]u8, timeout_ms: u64) PingResult {
    if (!rtl.isReady()) return .timeout;

    const dst_mac = arpResolveWithTimeout(dst_ip, 2000) orelse return .unreachable_no_arp;

    const seq = ping_seq;
    ping_seq +%= 1;
    ping_reply_received = false;

    // Build ICMP echo request with 32 bytes of payload.
    const payload_len: usize = 32;
    const icmp_len = ICMP_HDR + payload_len;

    const frame = buildEthHdr(dst_mac, ETH_IPV4, IPV4_HDR + icmp_len);
    _ = frame;
    buildIpHdr(dst_ip, PROTO_ICMP, icmp_len);

    const r = ETH_HDR + IPV4_HDR;
    tx_frame[r]     = ICMP_ECHO_REQUEST;
    tx_frame[r + 1] = 0;
    writeU16be(&tx_frame, r + 2, 0);
    writeU16be(&tx_frame, r + 4, 0x1337); // ID
    writeU16be(&tx_frame, r + 6, seq);
    var i: usize = 0;
    while (i < payload_len) : (i += 1) tx_frame[r + ICMP_HDR + i] = @intCast(i & 0xFF);
    const csum = ipChecksum(tx_frame[r .. r + icmp_len]);
    writeU16be(&tx_frame, r + 2, csum);

    rtl.sendFrame(tx_frame[0 .. ETH_HDR + IPV4_HDR + icmp_len]);

    // Wait for echo reply.
    const deadline = pit.jiffies + timeout_ms / 10; // jiffies at 100 Hz
    while (pit.jiffies < deadline) {
        asm volatile ("pause");
        if (ping_reply_received) return .ok;
    }
    return .timeout;
}

// ---- ARP resolution with timeout -------------------------------------------

fn arpResolveWithTimeout(ip: [4]u8, timeout_ms: u64) ?[6]u8 {
    if (arpCacheLookup(ip)) |m| return m;
    sendArpRequest(ip);
    const deadline = pit.jiffies + timeout_ms / 10;
    while (pit.jiffies < deadline) {
        asm volatile ("pause");
        if (arpCacheLookup(ip)) |m| return m;
    }
    return null;
}

fn resolveMac(dst_ip: [4]u8) ?[6]u8 {
    // Check if on-subnet.
    var same: bool = true;
    for (0..4) |i| {
        if ((dst_ip[i] & NETMASK[i]) != (MY_IP[i] & NETMASK[i])) { same = false; break; }
    }
    const lookup_ip = if (same) dst_ip else GW_IP;
    return arpResolveWithTimeout(lookup_ip, 2000);
}

// ---- Incoming frame handler ------------------------------------------------

fn onReceive(data: []const u8) void {
    if (data.len < ETH_HDR) return;

    const etype = readU16be(data, 12);
    switch (etype) {
        ETH_ARP => handleArp(data),
        ETH_IPV4 => handleIPv4(data),
        else => {},
    }
}

fn handleIPv4(data: []const u8) void {
    if (data.len < ETH_HDR + IPV4_HDR) return;
    const p = ETH_HDR;
    const proto = data[p + 9];
    const total_len = readU16be(data, p + 2);
    _ = total_len;

    var src_ip: [4]u8 = undefined;
    @memcpy(&src_ip, data[p+12 .. p+16]);
    var dst_ip: [4]u8 = undefined;
    @memcpy(&dst_ip, data[p+16 .. p+20]);

    // Learn sender.
    var src_mac: [6]u8 = undefined;
    @memcpy(&src_mac, data[6..12]);
    arpCacheStore(src_ip, src_mac);

    // Only process packets addressed to us.
    if (@as(u32, @bitCast(dst_ip)) != @as(u32, @bitCast(MY_IP))) return;

    switch (proto) {
        PROTO_ICMP => {
            // Check if this is a reply to our ping.
            const base = ETH_HDR + IPV4_HDR;
            if (data.len >= base + ICMP_HDR and data[base] == ICMP_ECHO_REPLY) {
                ping_reply_received = true;
            }
            handleIcmp(src_ip, src_mac, data);
        },
        PROTO_UDP => handleUdp(src_ip, data),
        else => {},
    }
}

// ---- Public init -----------------------------------------------------------

pub fn init() bool {
    if (!rtl.init()) return false;
    my_mac = rtl.macAddr();
    rtl.on_receive = onReceive;
    console.writeString("[net] stack ready — IP 10.0.2.15/24, GW 10.0.2.2\n");
    return true;
}

pub fn isReady() bool { return rtl.isReady(); }
