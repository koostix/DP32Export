#!/usr/bin/env python3
"""Independent reference implementation of the DP-32SD stem export, in Python.

It exists to cross-check the Swift code and to run the hardware comparison
without building anything. It follows docs/FORMAT.md and makes the same
refusals as DP32Core. It only ever reads the song folder.

  reference.py info    <song folder>
  reference.py render  <song folder> <new output folder> [--pad]
  reference.py compare <song folder> <folder holding hardware _TRKnn.WAV files>
  reference.py survey  <folder of song folders>...

Needs numpy.
"""
import os, struct, sys
import numpy as np

EDL_SIZE = 11563954
POOL, NODE, NODES = 0x5238, 192, 60000
FILE_LIST = 0xB02586
END, BEGIN, SILENCE = 0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFF


class Refuse(Exception):
    pass


def u16(b, o): return struct.unpack_from('<H', b, o)[0]
def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def u64(b, o): return struct.unpack_from('<Q', b, o)[0]


def parse_edl(b):
    if len(b) != EDL_SIZE: raise Refuse('edltable.sys is %d bytes, not %d' % (len(b), EDL_SIZE))
    if b[0:5] != b'TEAC\0' or b[8:14] != b'DP-32\0' or b[0x18:0x22] != b'DP-32_EDL\0':
        raise Refuse('edltable.sys does not carry the DP-32 signature')
    if (u32(b, 0x38), u32(b, 0x3C), u32(b, 0x58), u32(b, 0x5C), u32(b, 0x60)) != (1, 0x51F8, NODE, NODES, NODE * NODES):
        raise Refuse('edltable.sys header constants are not the known ones')
    rate, bits, fade = u32(b, 0x40), u16(b, 0x44), u32(b, 0x4C)
    if rate not in (44100, 48000) or bits not in (16, 24): raise Refuse('unsupported format %d Hz / %d bit' % (rate, bits))
    if fade * 100 != rate: raise Refuse('fade length %d does not match the sample rate' % fade)
    if b[FILE_LIST:FILE_LIST + 10] != b'File List\0': raise Refuse('file list not found')
    if u32(b, FILE_LIST + 0x10) > 998: raise Refuse('file list count is out of range')
    live, dead = {}, set()
    for s in range(998):
        o = FILE_LIST + 0x20 + 20 * s
        fid = u16(b, o)
        name = b[o + 4:o + 20].split(b'\0')[0].decode('latin1')
        if not name: continue
        if fid >= 0xFFF0: dead.add(name); continue
        if fid in live: raise Refuse('file id %d is listed twice' % fid)
        live[fid] = name

    def node(n, what):
        if n >= NODES: raise Refuse('%s points outside the node pool' % what)
        return POOL + NODE * n

    tracks = []
    for key in range(256):
        h = node(key, 'head')
        if u32(b, h + 8) != 4: raise Refuse('key %d has no version list' % key)
        cur, idx, first, last, count = (u32(b, h + k) for k in (0x28, 0x2C, 0x30, 0x34, 0x38))
        if count < 1 or count > NODES: raise Refuse('key %d version count is out of range' % key)
        n, prev, chain = first, BEGIN, []
        while n != END:
            o = node(n, 'track version')
            if u32(b, o + 8) != 1 or u32(b, o + 0xC) != key or u32(b, o + 4) != prev:
                raise Refuse('key %d version chain is broken' % key)
            chain.append(n); prev = n; n = u32(b, o)
            if len(chain) > count: break
        if len(chain) != count or chain[-1] != last or idx >= count or chain[idx] != cur:
            raise Refuse('key %d version list does not agree with its chain' % key)
        t = node(cur, 'track')
        pl = u32(b, t + 0x30)
        if u32(b, t + 0x38) != 1 or u32(b, t + 0x34) != pl: raise Refuse('key %d does not have exactly one playlist' % key)
        p = node(pl, 'playlist')
        pkey = u32(b, p + 0xC)
        if u32(b, p + 8) != 2 or pkey >= 256: raise Refuse('key %d playlist is not a playlist' % key)
        rfirst, rlast, rcount, total = u32(b, p + 0x30), u32(b, p + 0x34), u32(b, p + 0x38), u64(b, p + 0x58)
        regs, r, prev, pos = [], rfirst, BEGIN, 0
        while r != END:
            o = node(r, 'region')
            if u32(b, o + 8) != 3 or u32(b, o + 0xC) != pkey or u32(b, o + 4) != prev:
                raise Refuse('key %d region chain is broken' % key)
            fid, start, length, src, srcend = u32(b, o + 0x50), u64(b, o + 0x58), u64(b, o + 0x60), u64(b, o + 0x68), u64(b, o + 0x70)
            if start != pos or length == 0: raise Refuse('key %d regions do not tile the timeline' % key)
            if srcend != src + length - 1: raise Refuse('key %d region source range is inconsistent' % key)
            fin, fout = u32(b, o + 0x78), u32(b, o + 0x7C)
            if fid == SILENCE:
                regs.append(dict(file=None, start=start, len=length, src=0, fin=0, fout=0))
            else:
                if fid not in live: raise Refuse('key %d uses file id %d, which the file list does not hold' % (key, fid))
                if fin not in (0, fade) or fout not in (0, fade): raise Refuse('key %d has an unknown fade length' % key)
                regs.append(dict(file=live[fid], start=start, len=length, src=src, fin=fin, fout=fout))
            pos += length; prev = r; r = u32(b, o)
            if len(regs) > rcount: break
        if len(regs) != rcount or prev != rlast or pos != total:
            raise Refuse('key %d regions do not tile the timeline' % key)
        tracks.append(dict(key=key, track=key // 8 + 1, virtual=key % 8, regions=regs,
                           undone=count - 1 - idx, clone_of=None if pkey == key else pkey))
    return dict(rate=rate, bits=bits, fade=fade, tracks=tracks, dead=dead)


def wav_info(path):
    if os.path.islink(path) or not os.path.isfile(path): raise Refuse('%s is not a regular file' % os.path.basename(path))
    size = os.path.getsize(path)
    with open(path, 'rb') as f:
        h = f.read(12)
        if len(h) < 12 or h[:4] != b'RIFF' or h[8:12] != b'WAVE': raise Refuse('%s is not a WAV file' % os.path.basename(path))
        fmt = None; off = 12
        for _ in range(64):
            f.seek(off); c = f.read(8)
            if len(c) < 8: break
            cid, csz = c[:4], u32(c, 4)
            if cid == b'fmt ':
                d = f.read(min(csz, 16))
                if len(d) < 16: break
                fmt = dict(size=csz, tag=u16(d, 0), ch=u16(d, 2), rate=u32(d, 4), align=u16(d, 12), bits=u16(d, 14))
            elif cid == b'data':
                if fmt is None or off + 8 + csz > size: break
                fmt.update(offset=off + 8, frames=csz // fmt['align'] if fmt['align'] else 0, bytes=csz)
                return fmt
            off += 8 + csz + (csz & 1)
    raise Refuse('%s has no readable WAV header' % os.path.basename(path))


def plan(folder):
    """Returns (edl, stems, notes). Raises Refuse."""
    e = os.path.join(folder, 'edltable.sys')
    if os.path.islink(e) or not os.path.isfile(e): raise Refuse('there is no edltable.sys in this folder')
    edl = parse_edl(open(e, 'rb').read())
    N = edl['fade']
    disk = {}
    for f in os.listdir(folder):
        if not f.startswith('._'): disk.setdefault(f.lower(), f)
    infos, stems, notes = {}, [], []
    for t in edl['tracks']:
        regs = t['regions']
        if not any(r['file'] for r in regs): continue
        label = 'track %d' % t['track'] + ('' if t['virtual'] == 0 else ' virtual %d' % (t['virtual'] + 1))
        for j, r in enumerate(regs):
            nxt = regs[j + 1] if j + 1 < len(regs) else None
            prv = regs[j - 1] if j else None
            if not r['file']:
                if prv and prv['file'] and nxt and nxt['file']:
                    if r['len'] < N: raise Refuse('%s has a gap shorter than the %d-sample edge fade' % (label, N))
                    notes.append('%s has a gap between two clips; that case was never compared with the hardware' % label)
                continue
            name = r['file']
            if name.lower() not in disk: raise Refuse('%s needs %s, which is not in the folder' % (label, name))
            path = os.path.join(folder, disk[name.lower()])
            if name not in infos: infos[name] = wav_info(path)
            w = infos[name]
            if (w['size'], w['tag'], w['ch'], w['rate'], w['bits'], w['align']) != (16, 1, 1, edl['rate'], edl['bits'], edl['bits'] // 8):
                raise Refuse('%s is not a mono %d-bit %d Hz classic PCM file' % (name, edl['bits'], edl['rate']))
            if r['len'] < N: raise Refuse('%s has a clip shorter than the edge fade' % label)
            if nxt is None: raise Refuse('%s ends with audio at the very end of the timeline' % label)
            if w['frames'] < r['src'] + r['len'] + N: raise Refuse('%s is shorter than the edit list needs' % name)
            r['path'] = path; r['offset'] = w['offset']
            if nxt['file'] and r['fout'] == 0:
                notes.append('%s has a punch-in; its 10 ms crossfade follows the punch-out rule, which is the only one compared with the hardware' % label)
        if t['undone']: notes.append('%s has %d undone edit(s); the state the unit shows now is exported' % (label, t['undone']))
        if t['clone_of'] is not None: notes.append('%s is a clone of track %d' % (label, t['clone_of'] // 8 + 1))
        last = [r for r in regs if r['file']][-1]
        stems.append(dict(track=t['track'], virtual=t['virtual'], regions=regs, frames=last['start'] + last['len'] + N))
    if edl['bits'] == 16: notes.append('16-bit song: the edge fades were never compared with a hardware export')
    by_track = {}
    for s in stems: by_track.setdefault(s['track'], []).append(s)
    for s in stems:
        s['suffix'] = '_TRK%02d' % s['track'] + ('_V%d' % (s['virtual'] + 1) if len(by_track[s['track']]) > 1 else '')
    return edl, stems, sorted(set(notes))


def fade_tables(N):
    i = np.arange(N, dtype=np.int64)
    return (0x7FFFFF * i * i) // (N * N), np.minimum(((1 << 31) * (N - i)) // N, (1 << 31) - 1)


def mix(a, b, gin, gout):
    """a: outgoing tail, b: incoming head, both int64 arrays of 24-bit values."""
    p = a * gout
    acc = np.where(a > 0, p >> 16, np.where(a < 0, -(((-p) >> 16) + 1), 0)) + (b >> 8) * gin
    return np.where(acc >= 0, acc >> 15, -((-acc) >> 15) - 1)


def read_pcm(path, offset, bits, first, count):
    bps = bits // 8
    with open(path, 'rb') as f:
        f.seek(offset + first * bps); raw = f.read(count * bps)
    if len(raw) != count * bps: raise Refuse('short read from ' + os.path.basename(path))
    if bits == 16: return np.frombuffer(raw, dtype='<i2').astype(np.int64) << 8
    d = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int64)
    v = d[:, 0] | (d[:, 1] << 8) | (d[:, 2] << 16)
    return np.where(v >= 1 << 23, v - (1 << 24), v)


def render(edl, stem, total=None):
    N, bits = edl['fade'], edl['bits']
    gin, gout = fade_tables(N)
    out = np.zeros(max(stem['frames'], total or 0), dtype=np.int64)
    regs = stem['regions']; zero = np.zeros(N, dtype=np.int64)
    tail = lambda r: read_pcm(r['path'], r['offset'], bits, r['src'] + r['len'], N)
    for j, r in enumerate(regs):
        if not r['file']: continue
        st, e = r['start'], r['start'] + r['len']
        out[st:e] = read_pcm(r['path'], r['offset'], bits, r['src'], r['len'])
        a = tail(regs[j - 1]) if j and regs[j - 1]['file'] else zero
        out[st:st + N] = mix(a, out[st:st + N].copy(), gin, gout)
        if not regs[j + 1]['file']: out[e:e + N] = mix(tail(r), zero, gin, gout)
    return out


def encode(v, bits):
    if bits == 16: return (v >> 8).astype('<i2').tobytes()
    u = (v & 0xFFFFFF).astype(np.uint32)
    return np.stack([u & 0xFF, (u >> 8) & 0xFF, (u >> 16) & 0xFF], axis=1).astype(np.uint8).tobytes()


def wav_header(rate, bits, nbytes):
    return struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 36 + nbytes, b'WAVE', b'fmt ', 16, 1, 1, rate, rate * bits // 8, bits // 8, bits, b'data', nbytes)


def cmd_info(folder):
    edl, stems, notes = plan(folder)
    print('%d Hz / %d bit, fade %d' % (edl['rate'], edl['bits'], edl['fade']))
    for s in stems:
        clips = [r for r in s['regions'] if r['file']]
        print('  %s  %d samples (%.3f s), %d clip(s)' % (s['suffix'], s['frames'], s['frames'] / edl['rate'], len(clips)))
    for n in notes: print('  note:', n)


def cmd_render(folder, out, pad):
    edl, stems, notes = plan(folder)
    os.mkdir(out)  # fails if it exists
    name = os.path.basename(os.path.normpath(folder))
    total = max(s['frames'] for s in stems) if pad else None
    for s in stems:
        data = encode(render(edl, s, total), edl['bits'])
        with open(os.path.join(out, name + s['suffix'] + '.WAV'), 'xb') as f:
            f.write(wav_header(edl['rate'], edl['bits'], len(data))); f.write(data)
        print('wrote', name + s['suffix'] + '.WAV')


def cmd_compare(folder, hw):
    edl, stems, notes = plan(folder)
    name = os.path.basename(os.path.normpath(folder))
    total_diff = total_samples = 0
    for s in stems:
        path = os.path.join(hw, name + s['suffix'] + '.WAV')
        if not os.path.isfile(path): print(s['suffix'], 'no hardware file'); continue
        mine = render(edl, s)
        raw = open(path, 'rb').read()
        w = wav_info(path)
        theirs = read_pcm(path, w['offset'], edl['bits'], 0, w['frames'])
        hdr = raw[:44] == wav_header(edl['rate'], edl['bits'], len(mine) * edl['bits'] // 8)
        if len(mine) != len(theirs): print(s['suffix'], 'LENGTH differs', len(mine), len(theirs)); continue
        d = np.nonzero(mine != theirs)[0]
        head = d[d < edl['fade']] if not s['regions'][0]['file'] else d[:0]
        rest = np.setdiff1d(d, head)
        worst = int(np.abs(mine[rest] - theirs[rest]).max()) if len(rest) else 0
        total_diff += len(rest); total_samples += len(mine)
        print('%s header %s, %d samples, %d differ (largest %d LSB)%s%s' % (
            s['suffix'], 'identical' if hdr else 'DIFFERS', len(mine), len(rest), worst,
            ', byte-identical' if hdr and not len(d) else '',
            ', plus %d in the first %d samples where the edit list says silence (hardware artifact)' % (len(head), edl['fade']) if len(head) else ''))
    print('total: %d of %d samples differ' % (total_diff, total_samples))


def cmd_survey(roots):
    for root in roots:
        for d in sorted(os.listdir(root)):
            p = os.path.join(root, d)
            if not os.path.isfile(os.path.join(p, 'edltable.sys')): continue
            try:
                edl, stems, notes = plan(p)
                print('%-40s READY  %d/%d  %s  %.1f s  %d note(s)' % (d, edl['rate'], edl['bits'], ' '.join(s['suffix'][4:] for s in stems),
                                                             max([s['frames'] for s in stems] or [0]) / edl['rate'], len(notes)))
            except Refuse as x:
                print('%-40s REFUSED: %s' % (d, x))


if __name__ == '__main__':
    a = sys.argv[1:]
    try:
        if len(a) == 2 and a[0] == 'info': cmd_info(a[1])
        elif len(a) >= 3 and a[0] == 'render': cmd_render(a[1], a[2], '--pad' in a)
        elif len(a) == 3 and a[0] == 'compare': cmd_compare(a[1], a[2])
        elif len(a) >= 2 and a[0] == 'survey': cmd_survey(a[1:])
        else: print(__doc__); sys.exit(3)
    except Refuse as x:
        print('refused:', x); sys.exit(2)
