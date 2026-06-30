//! Minimal DNS resolver (A records over UDP).
//!
//! Builds a single recursion-desired query for one hostname, sends it to the
//! configured resolver (net.DNS_IP:53), polls the NIC for the reply, and parses
//! out the first A record. This is what lets userland reach hosts by name —
//! the IP stack already routes off-subnet traffic through the gateway, so once
//! a name resolves, TCP/UDP to it just works.
//!
//! Network input is untrusted: every read is bounds-checked and name parsing is
//! guarded against compression-pointer loops.

const net = @import("net.zig");
const rtl = @import("rtl8139.zig");

var next_id: u16 = 0x1a2b;

fn rd16(b: []const u8, o: usize) u16 {
    return (@as(u16, b[o]) << 8) | b[o + 1];
}

/// Encode `host` as a DNS question into `out`. Returns the query length.
fn buildQuery(host: []const u8, id: u16, out: []u8) ?usize {
    // header(12) + name(len+1) + null(1) + qtype(2) + qclass(2)
    if (out.len < 12 + host.len + 6) return null;
    out[0] = @intCast(id >> 8);
    out[1] = @intCast(id & 0xFF);
    out[2] = 0x01; // RD = 1 (recursion desired)
    out[3] = 0x00;
    out[4] = 0;
    out[5] = 1; // QDCOUNT = 1
    @memset(out[6..12], 0); // AN/NS/AR = 0

    var pos: usize = 12;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= host.len) : (i += 1) {
        if (i == host.len or host[i] == '.') {
            const llen = i - start;
            if (llen == 0 or llen > 63) return null; // empty/oversized label
            out[pos] = @intCast(llen);
            pos += 1;
            @memcpy(out[pos .. pos + llen], host[start..i]);
            pos += llen;
            start = i + 1;
        }
    }
    out[pos] = 0; // root label
    pos += 1;
    out[pos] = 0;
    out[pos + 1] = 1; // QTYPE = A
    out[pos + 2] = 0;
    out[pos + 3] = 1; // QCLASS = IN
    return pos + 4;
}

/// Advance past a DNS name at `pos`. A compression pointer (top two bits set)
/// terminates the name in two bytes. Returns the offset just after the name.
fn skipName(resp: []const u8, pos_in: usize) ?usize {
    var pos = pos_in;
    var guard: usize = 0;
    while (pos < resp.len) {
        guard += 1;
        if (guard > 128) return null; // malformed / loop
        const b = resp[pos];
        if (b == 0) return pos + 1;
        if (b & 0xC0 == 0xC0) return pos + 2; // pointer ends the name
        pos += 1 + b;
    }
    return null;
}

/// Parse a response, writing the first A record into `out`. Returns false on
/// any mismatch (wrong id, error rcode, no A record, truncation).
fn parseAnswer(resp: []const u8, id: u16, out: *[4]u8) bool {
    if (resp.len < 12) return false;
    if (rd16(resp, 0) != id) return false;
    if (resp[2] & 0x80 == 0) return false; // not a response
    if (resp[3] & 0x0F != 0) return false; // RCODE != 0 (e.g. NXDOMAIN)
    const qd = rd16(resp, 4);
    const an = rd16(resp, 6);
    if (an == 0) return false;

    var pos: usize = 12;
    var q: usize = 0;
    while (q < qd) : (q += 1) {
        pos = skipName(resp, pos) orelse return false;
        if (pos + 4 > resp.len) return false;
        pos += 4; // QTYPE + QCLASS
    }

    var a: usize = 0;
    while (a < an) : (a += 1) {
        pos = skipName(resp, pos) orelse return false;
        if (pos + 10 > resp.len) return false;
        const atype = rd16(resp, pos);
        const rdlen = rd16(resp, pos + 8);
        pos += 10;
        if (pos + rdlen > resp.len) return false;
        if (atype == 1 and rdlen == 4) { // A record
            out[0] = resp[pos];
            out[1] = resp[pos + 1];
            out[2] = resp[pos + 2];
            out[3] = resp[pos + 3];
            return true;
        }
        pos += rdlen;
    }
    return false;
}

/// Resolve `host` to an IPv4 address. Returns true and fills `out` on success.
pub fn resolve(host: []const u8, out: *[4]u8) bool {
    if (!rtl.isReady()) return false;
    if (host.len == 0 or host.len > 255) return false;

    var query: [512]u8 = undefined;
    const id = next_id;
    next_id +%= 1;
    const qlen = buildQuery(host, id, &query) orelse return false;
    const sport: u16 = 0xD000 +% (id & 0x0FFF);
    net.udpSend(net.DNS_IP, sport, 53, query[0..qlen]);

    var rbuf: [512]u8 = undefined;
    var src_ip: [4]u8 = undefined;
    var sp: u16 = 0;
    var dp: u16 = 0;
    // Poll for the reply. IRQs may be masked in a syscall, so spin on PIO RX;
    // ~5M iterations ≈ 1 s in QEMU. Allow ~3 s.
    const iters: usize = 3000 * 5000;
    var i: usize = 0;
    while (i < iters) : (i += 100) {
        rtl.pollRx();
        const n = net.udpRecv(&rbuf, &src_ip, &sp, &dp);
        if (n == 0) continue;
        if (dp != sport) continue; // not our query's reply
        if (parseAnswer(rbuf[0..n], id, out)) return true;
    }
    return false;
}
