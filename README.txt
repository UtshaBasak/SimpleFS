CSE 321 - Operating Systems
Lab Term Project, Summer 2026
SimpleFS: Implementation of a Simple File System in C


1. PROJECT INFORMATION
------------------------------------------------------------------------
Course   : CSE 321 - Operating Systems
Section  : 06
Semester : Summer 2026
Author   : Utsha Basak


2. FILES SUBMITTED
------------------------------------------------------------------------
    simplefs.h
    simplefs_builder.c
    simplefs_adder.c
    README.txt


3. COMPILATION
------------------------------------------------------------------------
Compiled and tested on Ubuntu 22.04.5 LTS, gcc 11.4.0

    gcc -Wall -Wextra -std=c11 simplefs_builder.c -o simplefs_builder
    gcc -Wall -Wextra -std=c11 simplefs_adder.c  -o simplefs_adder

Warnings: Both files compile with zero warnings and zero errors.


4. EXECUTION
------------------------------------------------------------------------
Created an empty file system:

    ./simplefs_builder --image disk.img
    ls -l disk.img

Add files:

    ./simplefs_adder --input disk.img --file test1.txt
    ./simplefs_adder --input disk.img --file test2.txt
    ./simplefs_adder --input disk.img --file test3.txt

Verification with xxd:

    xxd -s 4096  -l 8  disk.img
        Expected first byte 01 on a fresh image, 03 after one user file,
        0f after three. Bit i of the inode bitmap corresponds to inode
        i+1, so 03 means inode 1 (root) and inode 2 (the first file).

    xxd -s 8192  -l 8  disk.img
        Expected first byte 01 on a fresh image, 03 after one one-block
        file, 07 after one two-block file, 0f after one three-block file.
        Bit i of the data bitmap corresponds to absolute block i+4, so 03
        means block 4 (root directory) and block 5 (the first file).

    xxd -l 64 disk.img                  #superblock
    xxd -s 16384 -l 128 disk.img        #root directory
    xxd -s 20480 -l 64 disk.img         #first user data block (block 5).


5. IMPLEMENTATION DESCRIPTION
------------------------------------------------------------------------

5.1 simplefs_builder

simplefs_builder formats a new, empty SimpleFS image. It validates that it
was called as "--image <name>", creates the file in binary write mode, and
first writes 64 zero-filled 4096-byte blocks, which both establishes the
exact 262144-byte size and guarantees that every reserved byte the
specification requires to be zero really is zero before any metadata is
written.

It then fills the 36-byte superblock and writes it at the start of Block 0:
magic 0x53465331, block_size 4096, total_blocks 64, inode_count 32,
inode_bitmap_block 1, data_bitmap_block 2, inode_table_block 3,
data_region_block 4 and root_inode 1. The remaining 4060 bytes of Block 0
stay zero.

Next it allocates the root's two resources in the two bitmaps. The root is
inode 1, so bit 0 of the inode bitmap in Block 1 is set, making byte 4096
read 01. The root directory occupies absolute block 4, and the data bitmap
index of a block is (block - 4), so bit 0 of the data bitmap in Block 2 is
set, making byte 8192 read 01. Both bitmaps are then written out in full.

It builds the root inode and writes it as the first inode in Block 3, at
byte 12288: type = TYPE_DIRECTORY (2), links = 2 because both . and ..
refer to it, size = 128 because the directory already holds two 64-byte
entries, direct[0] = 4, direct[1] = direct[2] = 0, and reserved[108] left
zero.

Finally it builds the two mandatory directory entries and writes them at
the beginning of Block 4, byte 16384: entry 0 is "." and entry 1 is "..",
both with inode_no = 1 and type = TYPE_DIRECTORY, each name explicitly
null-terminated inside its 59-byte field. Both entries point at inode 1
because the root directory has no parent. The image is then closed.

5.2 simplefs_adder

simplefs_adder copies one regular file from the current working directory
into an existing image, and never modifies the source file. It performs
every validation before it writes a single byte, so a rejected request
always leaves the image exactly as it was.

It opens the image in binary read/update mode, reads the superblock and
refuses to continue unless the magic number is 0x53465331 - this is what
stops the program from damaging a file that is not a SimpleFS image. It
then opens the source file, determines its size with fseek/ftell, rejects
anything larger than MAX_FILE_SIZE (12288 bytes, the three direct pointers
times the block size), and rejects any file name longer than 58 characters,
since the 59-byte name field must also hold a terminating null.

The number of blocks needed is the integer ceiling
(file_size + BLOCK_SIZE - 1) / BLOCK_SIZE, so 0 bytes needs 0 blocks, 4096
needs 1, and 4097 needs 2. The root directory is then scanned entry by
entry and a duplicate file name is rejected with a bounded comparison over
the 59-byte name field.

Allocation is first fit and happens in two steps. The inode bitmap is read
from Block 1 and scanned from index 1 upwards - index 0 is the root and is
never available - and the first clear bit yields the inode number
(index + 1). The data bitmap is read from Block 2 and scanned from index 0;
each hit is converted to an absolute block number (4 + index), stored in
allocated_blocks[], and its bit is marked in the in-memory bitmap
immediately, before the next search, so that the same block cannot be
handed out twice. If the blocks run out, the request is rejected. A free
directory entry is located by scanning entries 2 through 63 for
inode_no == 0, entries 0 and 1 being permanently . and ..

The data is then copied one block at a time. For each allocated block a
4096-byte buffer is zeroed, up to 4096 bytes are read from the source into
it, and the full 4096 bytes are written at block_number * 4096. Zeroing
before every read is what guarantees that the unused tail of a partly
filled final block is zero, as the specification requires.

The metadata is written last, in an order that leaves the image consistent:
the new inode (type = TYPE_FILE, links = 1, size = the actual file size,
direct[i] = allocated_blocks[i] for the blocks in use and 0 for the rest)
at byte 12288 + (inode_number - 1) * 128; the inode bitmap bit for
(inode_number - 1) set and both bitmaps written back; the 64-byte directory
entry (inode_no, TYPE_FILE, and the name copied with at most 58 characters
and an explicit terminator) written at 16384 + entry_index * 64; and
finally the root inode's size increased by sizeof(dirent_t) = 64 bytes and
written back. Both files are then closed.


6. TESTING PERFORMED
------------------------------------------------------------------------
All fifteen test cases from the project specification section 19 were
run from a freshly created image each time, and the resulting bytes were
inspected with xxd rather than only checking that the programs ran:

    TC01  image created, exactly 262144 bytes
    TC02  superblock present and correct at byte 0
    TC03  inode bitmap byte 4096 = 01
    TC04  data bitmap byte 8192 = 01
    TC05  . and .. visible at byte 16384
    TC06  test1.txt added successfully
    TC07  inode bitmap byte 4096 = 03
    TC08  data bitmap byte 8192 = 03
    TC09  file contents present at byte 20480
    TC10  5000-byte file: data bitmap 07, direct[0]=5, direct[1]=6
    TC11  12288 bytes accepted, 12289 bytes rejected
    TC12  three files receive inodes 2, 3 and 4
    TC13  duplicate file name rejected
    TC14  missing source file reported, exits normally
    TC15  missing image reported, exits normally, no segmentation fault

Additional edge cases tested:

    - 0-byte file: consumes an inode and a directory entry but no data
      block; all three direct[] entries stay 0
    - size boundaries 4096, 4097, 8192 and 8193 produce 1, 2, 2 and 3
      blocks respectively
    - a 58-character file name is accepted, a 59-character name rejected
    - a random 262144-byte file is rejected as an invalid SimpleFS image
    - the source file is byte-identical (compared with cmp) after adding
    - the image stays exactly 262144 bytes after many additions
    - 31 files fill the inode table and the 32nd is rejected with
      "no free inode"
    - invalid and missing command-line arguments are reported and exit 1
    - no run ever terminated with a signal (no segmentation faults)


7. LIMITATIONS AND SIMPLIFICATIONS
------------------------------------------------------------------------
    - Only the root directory exists; there are no subdirectories and no
      multi-level path traversal.
    - No file deletion, renaming, hard links or symbolic links.
    - No indirect block pointers, so the maximum file size is
      3 x 4096 = 12288 bytes.
    - At most 31 regular files, because there are 32 inodes and inode 1
      is reserved for the root directory.
    - File names are limited to 58 characters so the 59-byte name field
      can hold a terminating null byte.
    - No permissions, timestamps, journaling, checksums or caching.
    - There is no separate read command; file contents are verified with
      xxd or hexdump.
    - The image is not a Linux-mountable file system and cannot be
      mounted; it is a plain 256 KiB binary file.
    - Source files must be in the current working directory; path
      arguments such as files/test1.txt are not supported.
