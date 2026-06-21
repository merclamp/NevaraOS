//! TCP stack for Nevara OS.
//!
//! Supports a fixed pool of sockets (TCP_MAX_SOCKS).
//! Implements the core RFC 793 state machine:
//!   CLOSED → LISTEN → SYN_RCVD → ESTABLISHED → CLOSE_WAIT → LAST_ACK
//!   CLOSED → SYN_SENT → ESTABLISHED → FIN_WAIT_1 → FIN_WAIT_2 → TIME_WAIT
//!
//! Limitations (acceptable for a hobby OS):
//!   - No sliding window congestion control (fixed window advertised)
//!   - No IP fragmentation
//!   - Retransmit: single retransmit queue entry per socket, 1s timeout
//!   - Max payload per segment: TCP_MSS bytes
//!   - Receive buffer: TCP_RBUF bytes per socket (ring buffer)

const net = @import("net.zig");
const pit = @import("../arch/x86_64/pit.zig");
const console = @import("../arch/x86_64/console.zig");

// ---- Constants ---------------------------------------------------------------

pub const TCP_MAX_SOCKS: usize = 16;
const TCP_MSS:  usize = 1460; // max segment payload
const TCP_RBUF: usize = 4096; // receive ring buffer per socket
const TCP_SBUF: usize = 4096; // send buffer per socket
const TCP_WINDOW: u16 = TCP_RBUF; // advertised window
const TCP_RETRANSMIT_TICKS: u64 = 100; // jiffies before retransmit (~1s at 100Hz)
const TCP_TIMEWAIT_TICKS:   u64 = 200; // 2s TIME_WAIT

// ---- TCP state ---------------------------------------------------------------

pub const TcpState = enum(u8) {
    closed     = 0,
    listen     = 1,
    syn_sent   = 2,
    syn_rcvd   = 3,
    established= 4,
    fin_wait1  = 5,
    fin_wait2  = 6,
    close_wait = 7,
    closing    = 8,
    last_ack   = 9,
    time_wait  = 10,
};

// ---- TCP flags ---------------------------------------------------------------

const FIN: u8 = 0x01;
const SYN: u8 = 0x02;
const RST: u8 = 0x04;
const PSH: u8 = 0x08;
const ACK: u8 = 0x10;

// ---- Socket ------------------------------------------------------------------

pub const TcpSocket = struct {
    state:     TcpState = .closed,
    // Addressing
    local_port:  u16 = 0,
    remote_ip:   [4]u8 = .{0,0,0,0},
    remote_port: u16 = 0,
    remote_mac:  [6]u8 = .{0,0,0,0,0,0},
    // Sequence numbers
    snd_nxt: u32 = 0,  // next byte to send
    snd_una: u32 = 0,  // oldest unacknowledged
    rcv_nxt: u32 = 0,  // next expected from peer
    // Receive ring buffer
    rbuf:  [TCP_RBUF]u8 = undefined,
    rhead: usize = 0, // write pointer (producer = network handler)
    rtail: usize = 0, // read pointer  (consumer = user read())
    // Retransmit: last unacked segment
    rtx_buf: [TCP_MSS + 60]u8 = undefined, // ETH+IP+TCP+payload
    rtx_len: usize = 0,
    rtx_seq: u32 = 0,
    rtx_deadline: u64 = 0, // jiffies deadline; 0 = nothing pending
    // TIME_WAIT deadline
    tw_deadline: u64 = 0,
    // Backlog for listen sockets: index into pool of accepted sockets
    backlog: [4]u8 = .{0xff, 0xff, 0xff, 0xff}, // socket indices, 0xff=empty
    listen_parent: u8 = 0xff, // for accepted sockets: parent listener index
};

// ---- Socket pool -------------------------------------------------------------

var socks: [TCP_MAX_SOCKS]TcpSocket = undefined;
var socks_init: bool = false;

fn initPool() void {
    if (socks_init) return;
    for (&socks) |*s| s.* = TcpSocket{};
    socks_init = true;
}

/// Allocate a free socket; returns 0xff on failure.
pub fn allocSock() u8 {
    initPool();
    for (&socks, 0..) |*s, i| {
        if (s.state == .closed) {
            s.* = TcpSocket{};
            return @intCast(i);
        }
    }
    return 0xff;
}

pub fn getSock(idx: u8) ?*TcpSocket {
    if (idx >= TCP_MAX_SOCKS) return null;
    return &socks[idx];
}

// ---- Sequence number helpers -------------------------------------------------

fn seqGt(a: u32, b: u32) bool { return @as(i32, @bitCast(a -% b)) > 0; }
fn seqGe(a: u32, b: u32) bool { return a == b or seqGt(a, b); }

// ---- Pseudo-header checksum for TCP ------------------------------------------

fn tcpChecksum(src_ip: [4]u8, dst_ip: [4]u8, tcp_seg: []const u8) u16 {
    var sum: u32 = 0;
    // Pseudo-header: src(4) dst(4) zero(1) proto=6(1) tcp_len(2)
    sum += (@as(u32, src_ip[0]) << 8) | src_ip[1];
    sum += (@as(u32, src_ip[2]) << 8) | src_ip[3];
    sum += (@as(u32, dst_ip[0]) << 8) | dst_ip[1];
    sum += (@as(u32, dst_ip[2]) << 8) | dst_ip[3];
    sum += 6; // protocol
    sum += @as(u32, @intCast(tcp_seg.len));
    // TCP segment
    var i: usize = 0;
    while (i + 1 < tcp_seg.len) : (i += 2) {
        sum += (@as(u32, tcp_seg[i]) << 8) | tcp_seg[i + 1];
    }
    if (i < tcp_seg.len) sum += @as(u32, tcp_seg[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

// ---- Build and send a TCP segment --------------------------------------------
// Uses net.tx_frame scratch buffer via net.buildTcpFrame().

fn sendSegment(s: *TcpSocket, flags: u8, payload: []const u8, seq: u32) void {
    const payload_len = @min(payload.len, TCP_MSS);
    net.buildTcpFrame(
        s.remote_mac, s.remote_ip,
        s.local_port, s.remote_port,
        seq, s.rcv_nxt,
        flags, TCP_WINDOW,
        payload[0..payload_len],
        s.remote_ip,
    );
    // If this segment carries data or SYN/FIN, save for possible retransmit.
    if (payload_len > 0 or (flags & (SYN | FIN)) != 0) {
        const frame_len = net.lastTcpFrameLen();
        if (frame_len <= s.rtx_buf.len) {
            _ = net.copyLastFrame(s.rtx_buf[0..]);
            s.rtx_len  = frame_len;
            s.rtx_seq  = seq;
            s.rtx_deadline = pit.jiffies + TCP_RETRANSMIT_TICKS;
        }
    }
    net.sendTcpFrame(payload_len);
}

fn sendAck(s: *TcpSocket) void {
    sendSegment(s, ACK, &.{}, s.snd_nxt);
}
fn sendSynAck(s: *TcpSocket) void {
    sendSegment(s, SYN | ACK, &.{}, s.snd_nxt);
}
fn sendFin(s: *TcpSocket) void {
    sendSegment(s, FIN | ACK, &.{}, s.snd_nxt);
    s.snd_nxt +%= 1;
}
fn sendRst(dst_mac: [6]u8, dst_ip: [4]u8, src_port: u16, dst_port: u16, seq: u32) void {
    net.buildTcpFrame(dst_mac, dst_ip, src_port, dst_port, seq, 0, RST, 0, &.{}, dst_ip);
    net.sendTcpFrame(0);
}

// ---- Receive ring helpers ----------------------------------------------------

fn rbufFree(s: *const TcpSocket) usize {
    const used = (s.rhead -% s.rtail) % TCP_RBUF;
    return TCP_RBUF - 1 - used;
}

fn rbufPush(s: *TcpSocket, data: []const u8) usize {
    var wrote: usize = 0;
    for (data) |b| {
        const next = (s.rhead + 1) % TCP_RBUF;
        if (next == s.rtail) break; // full
        s.rbuf[s.rhead] = b;
        s.rhead = next;
        wrote += 1;
    }
    return wrote;
}

pub fn rbufRead(idx: u8, buf: []u8) usize {
    const s = getSock(idx) orelse return 0;
    var n: usize = 0;
    while (n < buf.len and s.rtail != s.rhead) {
        buf[n] = s.rbuf[s.rtail];
        s.rtail = (s.rtail + 1) % TCP_RBUF;
        n += 1;
    }
    return n;
}

pub fn rbufAvail(idx: u8) usize {
    const s = getSock(idx) orelse return 0;
    return (s.rhead -% s.rtail) % TCP_RBUF;
}

// ---- Public API: active open (connect) ---------------------------------------

pub fn connect(idx: u8, dst_ip: [4]u8, dst_port: u16, src_port: u16) bool {
    const s = getSock(idx) orelse return false;
    if (s.state != .closed) return false;

    // Resolve MAC.
    const mac = net.resolveMacPub(dst_ip) orelse return false;

    s.* = TcpSocket{};
    s.local_port  = src_port;
    s.remote_ip   = dst_ip;
    s.remote_port = dst_port;
    s.remote_mac  = mac;
    s.snd_nxt     = pseudoRand();
    s.snd_una     = s.snd_nxt;
    s.state       = .syn_sent;

    sendSegment(s, SYN, &.{}, s.snd_nxt);
    s.snd_nxt +%= 1;
    return true;
}

fn pseudoRand() u32 {
    // Simple counter seeded from jiffies.
    const v = pit.jiffies;
    return @truncate(v ^ (v >> 16) ^ 0xDEAD_1337);
}

// ---- Public API: passive open (listen/accept) --------------------------------

pub fn listen(idx: u8, port: u16) bool {
    const s = getSock(idx) orelse return false;
    s.* = TcpSocket{};
    s.local_port = port;
    s.state = .listen;
    return true;
}

/// Returns index of accepted socket, or 0xff if none ready.
pub fn accept(listener_idx: u8) u8 {
    const ls = getSock(listener_idx) orelse return 0xff;
    if (ls.state != .listen) return 0xff;
    for (&ls.backlog) |*slot| {
        const cidx = slot.*;
        if (cidx == 0xff) continue;
        const cs = getSock(cidx) orelse continue;
        if (cs.state == .established) {
            slot.* = 0xff;
            return cidx;
        }
    }
    return 0xff;
}

// ---- Public API: send data ---------------------------------------------------

pub fn send(idx: u8, data: []const u8) usize {
    const s = getSock(idx) orelse return 0;
    if (s.state != .established) return 0;
    const payload_len = @min(data.len, TCP_MSS);
    sendSegment(s, PSH | ACK, data[0..payload_len], s.snd_nxt);
    s.snd_nxt +%= @intCast(payload_len);
    return payload_len;
}

// ---- Public API: close -------------------------------------------------------

pub fn close(idx: u8) void {
    const s = getSock(idx) orelse return;
    switch (s.state) {
        .established, .syn_rcvd => {
            s.state = .fin_wait1;
            sendFin(s);
        },
        .close_wait => {
            s.state = .last_ack;
            sendFin(s);
        },
        else => { s.state = .closed; },
    }
}

// ---- Incoming TCP segment handler --------------------------------------------
// Called from net.zig's IPv4 handler.

pub fn handleSegment(
    src_ip:   [4]u8,
    src_mac:  [6]u8,
    data:     []const u8, // full ethernet frame
) void {
    const base = 14 + 20; // ETH + IP
    if (data.len < base + 20) return;

    const tcp = data[base..];
    const src_port  = readU16(tcp, 0);
    const dst_port  = readU16(tcp, 2);
    const seq_num   = readU32(tcp, 4);
    const ack_num   = readU32(tcp, 8);
    const data_off  = (tcp[12] >> 4) * 4;
    const flags: u8 = tcp[13];
    // const window = readU16(tcp, 14);

    if (data_off < 20 or base + data_off > data.len) return;
    const payload = data[base + data_off ..];

    // Verify checksum.
    const csum = readU16(tcp, 16);
    if (csum != 0) { // optional, skip if zero
        var tcp_copy: [1500]u8 = undefined;
        const seg_len = @min(tcp.len, 1500);
        @memcpy(tcp_copy[0..seg_len], tcp[0..seg_len]);
        tcp_copy[16] = 0; tcp_copy[17] = 0;
        var src_ipv4: [4]u8 = undefined;
        @memcpy(&src_ipv4, data[26..30]);
        var dst_ipv4: [4]u8 = undefined;
        @memcpy(&dst_ipv4, data[30..34]);
        const computed = tcpChecksum(src_ipv4, dst_ipv4, tcp_copy[0..seg_len]);
        if (computed != 0 and computed != csum) return; // checksum mismatch
    }

    // Find matching socket.
    var sock_idx: u8 = 0xff;
    var listener_idx: u8 = 0xff;
    for (&socks, 0..) |*s, i| {
        if (s.state == .closed) continue;
        if (s.local_port != dst_port) continue;
        if (s.state == .listen) {
            listener_idx = @intCast(i);
            continue;
        }
        // Match established/connecting socket.
        if (@as(u32, @bitCast(s.remote_ip)) == @as(u32, @bitCast(src_ip)) and
            s.remote_port == src_port)
        {
            sock_idx = @intCast(i);
            break;
        }
    }

    // Handle incoming SYN for a listener.
    if (sock_idx == 0xff and listener_idx != 0xff and (flags & SYN) != 0 and (flags & ACK) == 0) {
        const ls = &socks[listener_idx];
        // Find empty backlog slot.
        var bslot: ?*u8 = null;
        for (&ls.backlog) |*slot| {
            if (slot.* == 0xff) { bslot = slot; break; }
        }
        const bs = bslot orelse return; // backlog full

        // Allocate new socket for this connection.
        const new_idx = allocSock();
        if (new_idx == 0xff) return;
        bs.* = new_idx;

        const ns = &socks[new_idx];
        ns.local_port    = dst_port;
        ns.remote_ip     = src_ip;
        ns.remote_port   = src_port;
        ns.remote_mac    = src_mac;
        ns.rcv_nxt       = seq_num +% 1;
        ns.snd_nxt       = pseudoRand();
        ns.snd_una       = ns.snd_nxt;
        ns.state         = .syn_rcvd;
        ns.listen_parent = listener_idx;

        sendSynAck(ns);
        ns.snd_nxt +%= 1;
        return;
    }

    if (sock_idx == 0xff) {
        // No socket; send RST if not already a RST.
        if ((flags & RST) == 0) {
            const rmac: [6]u8 = src_mac;
            sendRst(rmac, src_ip, dst_port, src_port, ack_num);
        }
        return;
    }

    const s = &socks[sock_idx];
    dispatch(s, flags, seq_num, ack_num, payload, src_mac);
}

fn dispatch(
    s:       *TcpSocket,
    flags:   u8,
    seq_num: u32,
    ack_num: u32,
    payload: []const u8,
    _src_mac: [6]u8,
) void {
    _ = _src_mac;

    // RST: hard close.
    if (flags & RST != 0) {
        s.state = .closed;
        return;
    }

    switch (s.state) {
        .syn_sent => {
            if ((flags & (SYN | ACK)) == (SYN | ACK)) {
                s.rcv_nxt = seq_num +% 1;
                s.snd_una = ack_num;
                s.state   = .established;
                sendAck(s);
                s.rtx_len = 0;
            }
        },
        .syn_rcvd => {
            if ((flags & ACK) != 0 and ack_num == s.snd_nxt) {
                s.snd_una = ack_num;
                s.state   = .established;
                s.rtx_len = 0;
            }
        },
        .established, .close_wait => {
            // Process ACK.
            if ((flags & ACK) != 0 and seqGe(ack_num, s.snd_una)) {
                s.snd_una = ack_num;
                if (s.rtx_len > 0 and seqGe(ack_num, s.rtx_seq +% @as(u32, @intCast(s.rtx_len)))) {
                    s.rtx_len = 0;
                    s.rtx_deadline = 0;
                }
            }
            // Deliver in-order payload.
            if (payload.len > 0 and seq_num == s.rcv_nxt) {
                const wrote = rbufPush(s, payload);
                s.rcv_nxt +%= @intCast(wrote);
                sendAck(s);
            }
            // FIN from peer.
            if ((flags & FIN) != 0 and seq_num == s.rcv_nxt) {
                s.rcv_nxt +%= 1;
                if (s.state == .established) {
                    s.state = .close_wait;
                } else { // close_wait: simultaneous close
                    s.state = .closing;
                }
                sendAck(s);
            }
        },
        .fin_wait1 => {
            if ((flags & ACK) != 0 and ack_num == s.snd_nxt) {
                s.snd_una = ack_num;
                s.rtx_len = 0;
                s.state   = .fin_wait2;
            }
            if ((flags & FIN) != 0 and seq_num == s.rcv_nxt) {
                s.rcv_nxt +%= 1;
                sendAck(s);
                s.state = .time_wait;
                s.tw_deadline = pit.jiffies + TCP_TIMEWAIT_TICKS;
            }
        },
        .fin_wait2 => {
            if ((flags & FIN) != 0 and seq_num == s.rcv_nxt) {
                s.rcv_nxt +%= 1;
                sendAck(s);
                s.state = .time_wait;
                s.tw_deadline = pit.jiffies + TCP_TIMEWAIT_TICKS;
            }
        },
        .last_ack => {
            if ((flags & ACK) != 0 and ack_num == s.snd_nxt) {
                s.state = .closed;
            }
        },
        .closing => {
            if ((flags & ACK) != 0) {
                s.state = .time_wait;
                s.tw_deadline = pit.jiffies + TCP_TIMEWAIT_TICKS;
            }
        },
        else => {},
    }
}

// ---- Periodic tick (called from IRQ0 / kernel idle) -------------------------

pub fn tick() void {
    if (!socks_init) return;
    const now = pit.jiffies;
    for (&socks) |*s| {
        // TIME_WAIT expiry.
        if (s.state == .time_wait and now >= s.tw_deadline) {
            s.state = .closed;
            continue;
        }
        // Retransmit.
        if (s.rtx_len > 0 and s.rtx_deadline != 0 and now >= s.rtx_deadline) {
            // Re-send saved frame.
            net.retransmitFrame(s.rtx_buf[0..s.rtx_len]);
            s.rtx_deadline = now + TCP_RETRANSMIT_TICKS;
        }
    }
}

// ---- Helpers -----------------------------------------------------------------

inline fn readU16(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | buf[off + 1];
}
inline fn readU32(buf: []const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) | (@as(u32, buf[off+1]) << 16) |
           (@as(u32, buf[off+2]) << 8) | buf[off+3];
}

pub fn isConnected(idx: u8) bool {
    const s = getSock(idx) orelse return false;
    return s.state == .established;
}
pub fn isListening(idx: u8) bool {
    const s = getSock(idx) orelse return false;
    return s.state == .listen;
}
pub fn isClosed(idx: u8) bool {
    const s = getSock(idx) orelse return true;
    return s.state == .closed;
}
pub fn hasData(idx: u8) bool {
    return rbufAvail(idx) > 0;
}
pub fn peerClosed(idx: u8) bool {
    const s = getSock(idx) orelse return true;
    return s.state == .close_wait or s.state == .last_ack or s.state == .closed;
}
