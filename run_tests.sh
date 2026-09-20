#!/usr/bin/env bash

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/testrun"

CC="gcc"
CFLAGS="-Wall -Wextra -std=c11"

pass=0
fail=0

# ---------------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------------

ok()   { pass=$((pass + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# check <description> <actual> <expected>
check() {
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        bad "$1 (expected '$3', got '$2')"
    fi
}

# ---------------------------------------------------------------------------
# Image inspection helpers
# ---------------------------------------------------------------------------

# byte <image> <offset> -> two hex digits, e.g. 03
byte() { xxd -s "$2" -l 1 -p "$1"; }

# u32 <image> <offset> -> the little-endian 32-bit value as a decimal number
u32() {
    local h
    h=$(xxd -s "$2" -l 4 -p "$1")
    printf '%d' "0x${h:6:2}${h:4:2}${h:2:2}${h:0:2}"
}

# u16 <image> <offset> -> the little-endian 16-bit value as a decimal number
u16() {
    local h
    h=$(xxd -s "$2" -l 2 -p "$1")
    printf '%d' "0x${h:2:2}${h:0:2}"
}

# Byte offsets, straight from the specification.
INODE_BITMAP=4096
DATA_BITMAP=8192
INODE_TABLE=12288
ROOT_DIR=16384

# inode_at <inode_number> -> byte offset of that inode: 12288 + (n - 1) * 128
inode_at() { echo $(( INODE_TABLE + ($1 - 1) * 128 )); }

# The fields inside a 128-byte inode.
i_type()   { u16 "$1" "$(( $(inode_at "$2") + 0 ))"; }
i_links()  { u16 "$1" "$(( $(inode_at "$2") + 2 ))"; }
i_size()   { u32 "$1" "$(( $(inode_at "$2") + 4 ))"; }
# i_direct <image> <inode_number> <0|1|2>
i_direct() { u32 "$1" "$(( $(inode_at "$2") + 8 + $3 * 4 ))"; }

# ---------------------------------------------------------------------------
# Command-running helpers
# ---------------------------------------------------------------------------

OUT=""
RC=0

run() { OUT=$("$@" 2>&1); RC=$?; }

# expect_ok <description> <command...>
expect_ok() {
    local desc="$1"; shift
    run "$@"
    if [ "$RC" -eq 0 ]; then
        ok "$desc"
    else
        bad "$desc (exit $RC: $OUT)"
    fi
}

# expect_fail <description> <message substring> <command...>
# Requires a non-zero exit, no crash, and a recognisable message.
expect_fail() {
    local desc="$1" want="$2"; shift 2
    run "$@"
    if [ "$RC" -ge 128 ]; then
        bad "$desc (CRASHED, signal $((RC - 128)))"
    elif [ "$RC" -eq 0 ]; then
        bad "$desc (accepted when it should have been rejected)"
    elif ! printf '%s' "$OUT" | grep -qi -- "$want"; then
        bad "$desc (rejected, but message was: $OUT)"
    else
        ok "$desc"
    fi
}

# fresh -- start every independent test from a brand-new image
fresh() {
    rm -f disk.img
    ./simplefs_builder --image disk.img > /dev/null
}

# ===========================================================================
# 0. Build
# ===========================================================================

head_ "Compiling (the specification requires a clean build)"

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$ROOT" || exit 1

berr=$($CC $CFLAGS simplefs_builder.c -o "$WORK/simplefs_builder" 2>&1); brc=$?
aerr=$($CC $CFLAGS simplefs_adder.c   -o "$WORK/simplefs_adder"   2>&1); arc=$?

if [ $brc -ne 0 ]; then bad "simplefs_builder.c compiles"; echo "$berr"; exit 1; else ok "simplefs_builder.c compiles"; fi
if [ $arc -ne 0 ]; then bad "simplefs_adder.c compiles";   echo "$aerr"; exit 1; else ok "simplefs_adder.c compiles";   fi

if [ -n "$berr" ]; then bad "simplefs_builder.c builds with no warnings"; echo "$berr"; else ok "simplefs_builder.c builds with no warnings"; fi
if [ -n "$aerr" ]; then bad "simplefs_adder.c builds with no warnings";   echo "$aerr"; else ok "simplefs_adder.c builds with no warnings";   fi

# Everything from here on happens in the scratch directory.
cp test1.txt test2.txt test3.txt "$WORK/"
cd "$WORK" || exit 1

# ===========================================================================
# Specification section 19: test cases 1 to 15
# ===========================================================================

head_ "TC01  Empty file system"
rm -f disk.img
expect_ok "builder creates an image" ./simplefs_builder --image disk.img
check "image is exactly 262144 bytes" "$(stat -c %s disk.img)" "262144"

head_ "TC02  Superblock"
check "magic at byte 0 is 0x53465331 (little-endian)" "$(xxd -l 4 -p disk.img)" "31534653"
check "block_size  = 4096" "$(u32 disk.img 4)"  "4096"
check "total_blocks = 64"  "$(u32 disk.img 8)"  "64"
check "inode_count  = 32"  "$(u32 disk.img 12)" "32"
check "inode_bitmap_block = 1" "$(u32 disk.img 16)" "1"
check "data_bitmap_block  = 2" "$(u32 disk.img 20)" "2"
check "inode_table_block  = 3" "$(u32 disk.img 24)" "3"
check "data_region_block  = 4" "$(u32 disk.img 28)" "4"
check "root_inode = 1"         "$(u32 disk.img 32)" "1"
check "the rest of block 0 is zero" \
      "$(xxd -s 36 -l 4060 -p disk.img | tr -d '\n0' | wc -c)" "0"

head_ "TC03  Initial inode bitmap"
check "byte 4096 is 01 (only inode 1, the root)" "$(byte disk.img $INODE_BITMAP)" "01"

head_ "TC04  Initial data bitmap"
check "byte 8192 is 01 (only block 4, the root directory)" "$(byte disk.img $DATA_BITMAP)" "01"

head_ "TC05  Root directory and root inode"
check "root inode type  = 2 (directory)" "$(i_type disk.img 1)"  "2"
check "root inode links = 2"             "$(i_links disk.img 1)" "2"
check "root inode size  = 128"           "$(i_size disk.img 1)"  "128"
check "root inode direct[0] = 4"         "$(i_direct disk.img 1 0)" "4"
check "root inode direct[1] = 0"         "$(i_direct disk.img 1 1)" "0"
check "root inode direct[2] = 0"         "$(i_direct disk.img 1 2)" "0"
check "entry 0 inode_no = 1" "$(u32 disk.img $ROOT_DIR)" "1"
check "entry 0 type = 2"     "$(byte disk.img $(( ROOT_DIR + 4 )))" "02"
check "entry 0 name is '.'"  "$(xxd -s $(( ROOT_DIR + 5 )) -l 2 -p disk.img)" "2e00"
check "entry 1 inode_no = 1" "$(u32 disk.img $(( ROOT_DIR + 64 )))" "1"
check "entry 1 type = 2"     "$(byte disk.img $(( ROOT_DIR + 68 )))" "02"
check "entry 1 name is '..'" "$(xxd -s $(( ROOT_DIR + 69 )) -l 3 -p disk.img)" "2e2e00"

head_ "TC06  Add a small file"
expect_ok "test1.txt is added" ./simplefs_adder --input disk.img --file test1.txt

head_ "TC07  Inode allocation after one file"
check "byte 4096 is 03 (inodes 1 and 2)" "$(byte disk.img $INODE_BITMAP)" "03"

head_ "TC08  Data allocation after one small file"
check "byte 8192 is 03 (blocks 4 and 5)" "$(byte disk.img $DATA_BITMAP)" "03"

head_ "TC09  File contents"
check "block 5 contains the file text" \
      "$(xxd -s 20480 -l 22 -p disk.img | xxd -r -p)" "$(cat test1.txt)"
check "inode 2 size is the real file size" "$(i_size disk.img 2)" "$(stat -c %s test1.txt)"
check "inode 2 type = 1 (regular file)"    "$(i_type disk.img 2)" "1"
check "inode 2 links = 1"                  "$(i_links disk.img 2)" "1"
check "inode 2 direct[0] = 5"              "$(i_direct disk.img 2 0)" "5"
check "inode 2 direct[1] = 0"              "$(i_direct disk.img 2 1)" "0"
check "root directory entry 2 points at inode 2" "$(u32 disk.img $(( ROOT_DIR + 128 )))" "2"
check "root inode size grew to 192"        "$(i_size disk.img 1)" "192"

head_ "TC10  Two-block file"
dd if=/dev/zero of=big5000.dat bs=1 count=5000 status=none
fresh
expect_ok "5000-byte file is added" ./simplefs_adder --input disk.img --file big5000.dat
check "byte 8192 is 07 (blocks 4, 5 and 6)" "$(byte disk.img $DATA_BITMAP)" "07"
check "direct[0] = 5" "$(i_direct disk.img 2 0)" "5"
check "direct[1] = 6" "$(i_direct disk.img 2 1)" "6"
check "direct[2] = 0" "$(i_direct disk.img 2 2)" "0"
check "size is 5000, not 8192" "$(i_size disk.img 2)" "5000"
check "the tail of block 6 is zero" \
      "$(xxd -s $(( 6 * 4096 + 904 )) -l 3192 -p disk.img | tr -d '\n0' | wc -c)" "0"

head_ "TC11  Maximum file size"
dd if=/dev/zero of=maxfile.dat bs=1 count=12288 status=none
dd if=/dev/zero of=too_big.dat bs=1 count=12289 status=none
fresh
expect_ok "12288 bytes is accepted" ./simplefs_adder --input disk.img --file maxfile.dat
check "it uses three blocks: 5, 6 and 7" \
      "$(i_direct disk.img 2 0)$(i_direct disk.img 2 1)$(i_direct disk.img 2 2)" "567"
check "byte 8192 is 0f (blocks 4, 5, 6 and 7)" "$(byte disk.img $DATA_BITMAP)" "0f"
expect_fail "12289 bytes is rejected" "too large" ./simplefs_adder --input disk.img --file too_big.dat

head_ "TC12  Multiple files"
fresh
expect_ok "test1.txt added" ./simplefs_adder --input disk.img --file test1.txt
expect_ok "test2.txt added" ./simplefs_adder --input disk.img --file test2.txt
expect_ok "test3.txt added" ./simplefs_adder --input disk.img --file test3.txt
check "byte 4096 is 0f (inodes 1, 2, 3 and 4)" "$(byte disk.img $INODE_BITMAP)" "0f"
check "the three files got inodes 2, 3 and 4" \
      "$(u32 disk.img $(( ROOT_DIR + 128 )))$(u32 disk.img $(( ROOT_DIR + 192 )))$(u32 disk.img $(( ROOT_DIR + 256 )))" "234"
check "root inode size grew to 320" "$(i_size disk.img 1)" "320"

head_ "TC13  Duplicate file name"
expect_fail "adding test1.txt twice is rejected" "already exists" \
    ./simplefs_adder --input disk.img --file test1.txt
check "the image is still 262144 bytes" "$(stat -c %s disk.img)" "262144"
check "the inode bitmap did not change"  "$(byte disk.img $INODE_BITMAP)" "0f"

head_ "TC14  Missing source file"
expect_fail "a missing source file is reported" "source file not found" \
    ./simplefs_adder --input disk.img --file abc123.txt

head_ "TC15  Missing image"
expect_fail "a missing image is reported" "image not found" \
    ./simplefs_adder --input nothing.img --file test1.txt

# ===========================================================================
# Additional edge cases
# ===========================================================================

head_ "EX01  Zero-byte file"
: > empty.dat
fresh
expect_ok "an empty file is accepted" ./simplefs_adder --input disk.img --file empty.dat
check "it consumes an inode" "$(byte disk.img $INODE_BITMAP)" "03"
check "it consumes no data block" "$(byte disk.img $DATA_BITMAP)" "01"
check "size = 0" "$(i_size disk.img 2)" "0"
check "all three direct pointers stay 0" \
      "$(i_direct disk.img 2 0)$(i_direct disk.img 2 1)$(i_direct disk.img 2 2)" "000"

head_ "EX02  Block-count boundaries"
for pair in "4096 03" "4097 07" "8192 07" "8193 0f"; do
    set -- $pair
    size=$1; want=$2
    dd if=/dev/zero of=bound.dat bs=1 count="$size" status=none
    fresh
    ./simplefs_adder --input disk.img --file bound.dat > /dev/null
    check "$size bytes gives data bitmap $want" "$(byte disk.img $DATA_BITMAP)" "$want"
done

head_ "EX03  File-name length limit"
n58=$(printf 'a%.0s' $(seq 1 54)).txt        # 54 + 4 = 58 characters
n59=$(printf 'b%.0s' $(seq 1 55)).txt        # 55 + 4 = 59 characters
echo data > "$n58"; echo data > "$n59"
fresh
expect_ok   "a 58-character name is accepted" ./simplefs_adder --input disk.img --file "$n58"
expect_fail "a 59-character name is rejected" "too long" ./simplefs_adder --input disk.img --file "$n59"
check "the 58-character name is stored null-terminated" \
      "$(byte disk.img $(( ROOT_DIR + 128 + 5 + 58 )))" "00"

head_ "EX04  Invalid image"
dd if=/dev/urandom of=junk.img bs=1024 count=256 status=none
expect_fail "random data is rejected as an image" "invalid" \
    ./simplefs_adder --input junk.img --file test1.txt

head_ "EX05  The source file is never modified"
fresh
cp test2.txt reference.txt
./simplefs_adder --input disk.img --file test2.txt > /dev/null
if cmp -s test2.txt reference.txt; then ok "test2.txt is byte-identical after adding"
else bad "test2.txt was modified"; fi

head_ "EX06  Command-line handling"
expect_fail "no arguments"        "Usage"   ./simplefs_adder
expect_fail "wrong option name"   "invalid" ./simplefs_adder --img disk.img --file test1.txt
expect_fail "builder, no image"   "Usage"   ./simplefs_builder
expect_fail "builder, bad option" "expected" ./simplefs_builder --disk disk.img

head_ "EX07  Filling the file system"
fresh
for i in $(seq 1 31); do
    echo "file $i" > "fill$i.dat"
    ./simplefs_adder --input disk.img --file "fill$i.dat" > /dev/null 2>&1
done
check "31 files fill all 32 inodes" "$(xxd -s $INODE_BITMAP -l 4 -p disk.img)" "ffffffff"
check "root inode size is 128 + 31*64 = 2112" "$(i_size disk.img 1)" "2112"
echo "one too many" > fill32.dat
expect_fail "the 32nd file is rejected" "no free inode" \
    ./simplefs_adder --input disk.img --file fill32.dat
check "the image is still exactly 262144 bytes" "$(stat -c %s disk.img)" "262144"

head_ "EX08  Running out of data blocks"
fresh
for i in $(seq 1 20); do
    dd if=/dev/zero of="big$i.dat" bs=1 count=12288 status=none
    ./simplefs_adder --input disk.img --file "big$i.dat" > /dev/null 2>&1
done
dd if=/dev/zero of=onemore.dat bs=1 count=12288 status=none
expect_fail "the data region runs out cleanly" "data block" \
    ./simplefs_adder --input disk.img --file onemore.dat

head_ "EX09  The project's sample files are untouched"
for f in test1.txt test2.txt test3.txt; do
    if cmp -s "$f" "$ROOT/$f"; then ok "$f is unchanged in the project directory"
    else bad "$f was modified"; fi
done

# ===========================================================================

head_ "Summary"
printf '  %d passed, %d failed\n\n' "$pass" "$fail"

if [ "$fail" -eq 0 ]; then
    printf '\033[32mAll checks passed.\033[0m Scratch files are in %s\n' "$WORK"
    exit 0
else
    printf '\033[31m%d check(s) failed.\033[0m Scratch files are in %s\n' "$fail" "$WORK"
    exit 1
fi
