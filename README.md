# SimpleFS

A minimal Unix-style file system implemented in C on top of a single 256 KiB
binary image file. Built for **CSE 321 (Operating Systems)**, Lab Term
Project, Summer 2026 — Section 06.

SimpleFS is not mountable. It is a flat binary image whose internal layout
mirrors how a real inode-based file system organises a disk: a superblock,
two allocation bitmaps, an inode table, and a data region. Two command-line
tools operate on it — one formats a fresh image, the other copies a file into
an existing one.

## On-disk layout

The image is exactly 64 blocks of 4096 bytes (262,144 bytes).

| Block | Byte offset | Contents |
|------:|------------:|----------|
| 0     | 0           | Superblock (36 bytes used, rest zero) |
| 1     | 4096        | Inode bitmap — bit *i* ↔ inode *i+1* |
| 2     | 8192        | Data bitmap — bit *i* ↔ absolute block *i+4* |
| 3     | 12288       | Inode table — 32 inodes × 128 bytes |
| 4–63  | 16384       | Data region — 60 blocks; block 4 is the root directory |

Key parameters (see [`simplefs.h`](simplefs.h)):

- Magic number `0x53465331`
- 32 inodes; inode 1 is the root directory, so at most **31 regular files**
- 3 direct block pointers per inode and no indirect blocks, giving a
  **maximum file size of 12,288 bytes**
- 64-byte directory entries; file names up to **58 characters** (the 59-byte
  name field must hold a terminating null)

## Building

Developed and tested on Ubuntu 22.04.5 LTS with gcc 11.4.0. Both files
compile with zero warnings.

```sh
gcc -Wall -Wextra -std=c11 simplefs_builder.c -o simplefs_builder
gcc -Wall -Wextra -std=c11 simplefs_adder.c   -o simplefs_adder
```

## Usage

Format a new, empty image:

```sh
./simplefs_builder --image disk.img
```

Copy a file from the current directory into the image:

```sh
./simplefs_adder --input disk.img --file test1.txt
```

`simplefs_adder` validates everything before writing a single byte, so a
rejected request leaves the image untouched. It refuses images whose magic
number does not match, files over 12,288 bytes, names over 58 characters,
and duplicate names.

## Inspecting an image

```sh
xxd -l 64        disk.img   # superblock
xxd -s 4096  -l 8  disk.img # inode bitmap
xxd -s 8192  -l 8  disk.img # data bitmap
xxd -s 16384 -l 128 disk.img # root directory ("." and "..")
xxd -s 20480 -l 64 disk.img # first user data block (block 5)
```

On a fresh image both bitmaps start at `01`. After adding one one-block file
they read `03`; after three such files, `0f`.

## Tests

[`run_tests.sh`](run_tests.sh) runs all fifteen test cases from the project
specification plus a set of edge cases (0-byte files, the 4096/4097/8192/8193
block boundaries, 58- vs 59-character names, filling the inode table,
rejecting a non-SimpleFS image, and confirming the source file is unmodified).
It verifies results at the byte level with `xxd` rather than only checking
exit codes.

```sh
./run_tests.sh
```

Requires `gcc` and `xxd`; run it from a Linux/WSL shell.

## Limitations

Root directory only — no subdirectories, no path traversal. No delete,
rename, links, permissions, timestamps, journaling or caching. Source files
must live in the current working directory.

## Author

Utsha Basak

[`README.txt`](README.txt), the original submission document, carries the full
implementation walkthrough and the complete test log.
