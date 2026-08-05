#!/usr/bin/env python3
"""Generate a classic-format icns (is32/il32/ih32/it32 + 8-bit masks) from
the 128x128 PNG entry (ic07) of a modern icns.

Pre-10.7 ImageIO cannot decode PNG- or ARGB-payload icns entries, and its
JPEG2000 error path (Kakadu, statically linked into ImageIO) reports
failure by throwing a C++ exception, which is fatal on 10.5/10.6 PPC when
mixed C++ runtimes are in the process (see vo_gpu/cocoa icon commits). The
classic entries produced here predate all of that and decode everywhere.

Usage: gen-legacy-icns.py <modern.icns> <legacy.icns>
"""

import struct
import sys
import zlib


def extract_ic07(path):
    data = open(path, 'rb').read()
    assert data[:4] == b'icns'
    off = 8
    while off < len(data):
        typ = data[off:off + 4]
        ln = struct.unpack('>I', data[off + 4:off + 8])[0]
        if typ == b'ic07':
            return data[off + 8:off + ln]
        off += ln
    raise SystemExit('no ic07 (128x128 PNG) entry found')


def decode_png_rgba8(png):
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    w, h, depth, ctype, comp, filt, inter = struct.unpack('>IIBBBBB',
                                                          png[16:29])
    assert (depth, ctype, inter) == (8, 6, 0), 'need RGBA8 non-interlaced'
    idat = b''
    off = 8
    while off < len(png):
        ln, typ = struct.unpack('>I4s', png[off:off + 8])
        if typ == b'IDAT':
            idat += png[off + 8:off + 8 + ln]
        off += 12 + ln
    raw = zlib.decompress(idat)
    stride = 4 * w
    out = bytearray(h * stride)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        ftype = raw[pos]
        pos += 1
        row = bytearray(raw[pos:pos + stride])
        pos += stride
        if ftype == 1:      # Sub
            for i in range(4, stride):
                row[i] = (row[i] + row[i - 4]) & 0xff
        elif ftype == 2:    # Up
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xff
        elif ftype == 3:    # Average
            for i in range(stride):
                a = row[i - 4] if i >= 4 else 0
                row[i] = (row[i] + ((a + prev[i]) >> 1)) & 0xff
        elif ftype == 4:    # Paeth
            for i in range(stride):
                a = row[i - 4] if i >= 4 else 0
                b = prev[i]
                c = prev[i - 4] if i >= 4 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                row[i] = (row[i] + pr) & 0xff
        else:
            assert ftype == 0, 'bad filter %d' % ftype
        out[y * stride:(y + 1) * stride] = row
        prev = row
    return w, h, bytes(out)


def resample(src_w, src_h, rgba, dst):
    """Area-average downsample on premultiplied alpha (avoids halos)."""
    sf = src_w / dst
    out = bytearray(dst * dst * 4)
    for ty in range(dst):
        y0, y1 = int(ty * sf), max(int((ty + 1) * sf), int(ty * sf) + 1)
        for tx in range(dst):
            x0, x1 = int(tx * sf), max(int((tx + 1) * sf), int(tx * sf) + 1)
            r = g = b = a = 0
            n = (y1 - y0) * (x1 - x0)
            for sy in range(y0, y1):
                base = sy * src_w * 4
                for sx in range(x0, x1):
                    i = base + sx * 4
                    al = rgba[i + 3]
                    r += rgba[i] * al
                    g += rgba[i + 1] * al
                    b += rgba[i + 2] * al
                    a += al
            o = (ty * dst + tx) * 4
            if a:
                out[o] = min(255, (r + a // 2) // a)
                out[o + 1] = min(255, (g + a // 2) // a)
                out[o + 2] = min(255, (b + a // 2) // a)
            out[o + 3] = (a + n // 2) // n
    return bytes(out)


def rle_channel(ch):
    """icns PackBits-style RLE: ctrl<0x80 = ctrl+1 literals; ctrl>=0x80 =
    (ctrl-0x80+3) repeats of next byte."""
    out = bytearray()
    i, n = 0, len(ch)
    lit = bytearray()

    def flush():
        j = 0
        while j < len(lit):
            k = min(128, len(lit) - j)
            out.append(k - 1)
            out.extend(lit[j:j + k])
            j += k
        lit.clear()

    while i < n:
        run = 1
        while i + run < n and run < 130 and ch[i + run] == ch[i]:
            run += 1
        if run >= 3:
            flush()
            out.append(0x80 + run - 3)
            out.append(ch[i])
            i += run
        else:
            lit += ch[i:i + run]
            i += run
    flush()
    return bytes(out)


def rle_decode(data, expect):
    out = bytearray()
    i = 0
    while len(out) < expect:
        c = data[i]
        i += 1
        if c >= 0x80:
            out += bytes([data[i]]) * (c - 0x80 + 3)
            i += 1
        else:
            out += data[i:i + c + 1]
            i += c + 1
    assert len(out) == expect
    return bytes(out), i


def chunk(typ, payload):
    return typ + struct.pack('>I', len(payload) + 8) + payload


def main():
    modern, legacy = sys.argv[1], sys.argv[2]
    w, h, rgba = decode_png_rgba8(extract_ic07(modern))

    # (size, rgb chunk, mask chunk, it32-style 4-byte zero header?)
    plan = [(16, b'is32', b's8mk', False),
            (32, b'il32', b'l8mk', False),
            (48, b'ih32', b'h8mk', False),
            (128, b'it32', b't8mk', True)]

    body = b''
    for size, ctyp, mtyp, hdr in plan:
        img = rgba if size == w else resample(w, h, rgba, size)
        chans = [bytes(img[c::4]) for c in (0, 1, 2, 3)]
        enc = b''.join(rle_channel(c) for c in chans[:3])
        # self-check: round-trip each channel
        rest = enc
        for c in chans[:3]:
            dec, used = rle_decode(rest, size * size)
            assert dec == c
            rest = rest[used:]
        payload = (b'\0\0\0\0' if hdr else b'') + enc
        body += chunk(ctyp, payload)
        body += chunk(mtyp, chans[3])          # mask: raw 8-bit alpha

    icns = b'icns' + struct.pack('>I', len(body) + 8) + body
    open(legacy, 'wb').write(icns)
    print('%s: %d bytes' % (legacy, len(icns)))


if __name__ == '__main__':
    main()
