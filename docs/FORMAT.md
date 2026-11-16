# DP-32SD song format, as used by DP32Export

Worked out from 49 song folders (44 on the owner's card, 5 copied to the Mac) and
checked against one hardware Audio Depot export (`20251102_0002`, 24-bit / 48 kHz).
Everything here is read-only knowledge: nothing in this project writes a card.

## Song folder

| File | Notes |
| --- | --- |
| `edltable.sys` | The edit list. Always 11,563,954 bytes. Everything below is about this file. |
| `song.sys` | 2,996 bytes, mixer settings. Not read. |
| `ZZnnnn_c.wav` | Raw clips: mono, classic PCM (fmt chunk 16 bytes), 16/44.1 or 24/48. No position data. |
| `{song}.WAV`, `{song}_z.WAV` | Stereo master and previous master, when present. Found by being stereo WAVs that are not `ZZ` files, so a folder renamed on the Mac still finds them. |

## edltable.sys

Little-endian throughout.

| Offset | Meaning |
| --- | --- |
| 0x00 / 0x08 / 0x18 | `TEAC\0`, `DP-32\0`, `DP-32_EDL\0` |
| 0x38, 0x3C | 1, 0x51F8 |
| 0x40 | u32 sample rate |
| 0x44 | u16 bits per sample |
| 0x4C | u32 edge fade length = rate / 100 (441 or 480) |
| 0x58, 0x5C, 0x60 | 192 (node size), 60,000 (node count), 11,520,000 |
| 0x5238 | Node pool: node `n` is at `0x5238 + 192 n` |
| 0xB02586 | `File List\0`, u32 count at +0x10, 998 slots of 20 bytes from +0x20 |

Every node starts with next (+0x00) and previous (+0x04) ids. 0xFFFFFFFE ends a
list forward, 0xFFFFFFFF backward. +0x08 is the type, +0x0C the key.

The key is `(track - 1) * 8 + virtual`, track 1–32, virtual 0–7.

### Key heads, type 4 — node ids 0–255 (new)

Node `n` for `n` in 0–255 is the head of key `n`'s version list.

| Offset | Meaning |
| --- | --- |
| +0x28 | Current track node |
| +0x2C | Index of the current node in the version list |
| +0x30 / +0x34 | First / last track node of the list |
| +0x38 | Number of versions |

**Undo answer.** The current state is the node the head names, not the end of the
chain. On 47 of 49 songs they are the same. In `20260507_0001`, keys 208 and 216
(tracks 27 and 28) have four versions with index 2 current: the newer, undone
version refers to a clip that the file list no longer holds. Reading the last
node there would have produced a wrong file, or no file. DP32Export follows the
head and notes the undone edits in the report. Not yet compared with a hardware
export.

### Track node, type 1

Versions of one key, linked oldest first. +0x30 playlist id, +0x34 the same,
+0x38 = 1 (playlist count).

### Playlist node, type 2

+0x0C its key, +0x30 first region, +0x34 last region, +0x38 region count,
+0x58 **u64** timeline length (0xF8000000 in most songs; 0x7B98A0000 in two).

**Clones (new).** A track node may point at a playlist whose key is another
track's. `20260720_0002` track 8 does this with track 3's playlist. The track is
exported with track 3's clips and the report says so.

### Region node, type 3

Regions tile the timeline from 0 to the playlist's length, silence included.

| Offset | Meaning |
| --- | --- |
| +0x50 | File id, 0xFFFFFFFF for silence |
| +0x54 | 0x100 \| input bit for audio (0x101, 0x102, 0x104 … for inputs 1, 2, 3 …); 0x4000 or 0 for silence. Not read. |
| +0x58 | u64 timeline start |
| +0x60 | u64 length |
| +0x68 | u64 first sample read from the file (silence: the timeline start) |
| +0x70 | u64 last sample = +0x68 + length − 1 |
| +0x78 | Fade-in length when the region starts at the file's first sample, else 0 |
| +0x7C | Fade-out length when the region ends one fade length before the file's end, else 0 |

The four fields are 64-bit. `20260912_0001` and `20261009_0001` use the high words.

### File list

Slot: u16 file id, u16 (same, or 0xFFFE in a few songs), 16-byte name. Regions use
the id, not the slot number. Id 0xFFFB names a file the current state no longer
uses. Names must look like `ZZ…​.wav` and contain only letters, digits, `_` and `.`.

## Clip edges

Each clip file holds one fade length N of extra audio after the region's last
sample. All values are 24-bit (16-bit songs are shifted up 8 bits first). `a` is
the outgoing audio (the extra audio after a clip that just stopped, 0 if none),
`b` the incoming clip, `i` = 0 … N−1.

```
gin[i]  = floor(0x7FFFFF * i² / N²)                       Q23, quadratic
gout[i] = min(floor(2³¹ * (N − i) / N), 2³¹ − 1)          Q31, linear

A   = a > 0 ?  (a * gout[i]) >> 16
    : a < 0 ? −(((−a) * gout[i]) >> 16) − 1
    : 0
acc = A + (b >> 8) * gin[i]
out = acc ≥ 0 ? acc >> 15 : −((−acc) >> 15) − 1
```

- A clip after silence: `a = 0`. Matches all 4,320 hardware samples.
- A clip followed by silence: `b = 0`, applied over the N samples after the clip,
  so a stem runs N samples past its last clip.
- A clip that starts where another stops: both at once.

On the reference song this leaves **7 samples in 48,190,400** differing from the
hardware, each by 1 LSB (the earlier `floor((s(N−i) − 1)/N)` rule left 19). They
are listed in `Tests/DP32CoreTests/FadeTests.swift`. The negative-side bias looks
like ones'-complement rounding in a fixed-point DSP; the exact last step is still
unknown.

16-bit songs: no hardware export exists to compare with. The report says so.

## Things refused on purpose

A song is refused, with a reason, when any of these is true: wrong size or
signature; unknown header constants or format; a broken list link; a node of the
wrong type or key; regions that do not tile the timeline exactly; a source range
that does not add up; a file id the list does not hold; an unknown fade length; a
clip file missing, not mono, wrong format, or too short; a clip or a gap between
clips shorter than the fade length; audio running to the end of the timeline.

## Hardware quirks

The unit's `TRK08.WAV` of the reference song starts with 480 samples of track 7's
fade-out, where the edit list says silence. That is left over in the unit. We
write silence.

## Still unknown

- Which virtual track is assigned. `song.sys` has 20-byte records from 0x14 whose
  first byte is sometimes 1, but they do not line up with the virtual-track songs.
  Every virtual track with audio is exported, `_V1`, `_V2` … only when a track has
  more than one.
- A gap between two clips, a punch-in (as opposed to a punch-out), a clone and an
  undo have never been compared with a hardware export. The report notes each.
- Stereo linking of tracks 9–32: each track is its own key and its own mono file,
  as the unit exports it.
