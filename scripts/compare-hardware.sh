#!/bin/sh
# Exports the reference song and compares it with the unit's own Audio Depot export.
#   sh scripts/compare-hardware.sh <folder> [<song name>]
# <folder> holds the song folder and the unit's own {song}_TRKnn.WAV export beside it.
# Defaults are the reference song used to work out the format.
set -eu
cd "$(dirname "$0")/.."
REF="${1:-$HOME/Desktop/_Music Projects/_Inbox/20251102_Classical Guitar Drums}"
SONG="${2:-20251102_0002}"
[ -d "$REF/$SONG" ] || { echo "Reference song not found at $REF/$SONG"; exit 3; }

swift build -c release --product dp32export
CLI="$(swift build -c release --show-bin-path)/dp32export"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

"$CLI" export "$REF/$SONG" --out "$OUT"
echo
STATUS=0
# The unit's TRK08 starts with 480 samples of track 7's fade-out where the edit list
# says silence. We write silence there, so those samples are counted separately.
"$CLI" compare "$OUT/$SONG" "$REF" --ignore-head "${SONG}_TRK08.WAV=480" --max-differences 19 > "$OUT/result.txt" || STATUS=$?
cat "$OUT/result.txt"
if ! grep -q "^${SONG}_TRK01.WAV: .*byte-identical" "$OUT/result.txt"; then
    echo "FAIL: track 1 is not byte-identical"
    exit 1
fi
if [ "$STATUS" -ne 0 ]; then
    echo "FAIL: a length or header differs, a sample is off by more than 1 LSB, or more than 19 samples differ"
    exit 1
fi
echo "PASS"
