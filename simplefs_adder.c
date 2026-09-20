#include "simplefs.h"

void set_bit(unsigned char *bitmap, int index) { bitmap[index / 8] |= (1u << (index % 8)); }
int is_bit_set(unsigned char *bitmap, int index) { return bitmap[index / 8] & (1u << (index % 8)); }
long inode_offset(int inode_number) { return ((long)INODE_TABLE_BLOCK * BLOCK_SIZE) + ((long)(inode_number - 1) * sizeof(inode_t)); }
int data_bitmap_index(int absolute_block_number) { return absolute_block_number - DATA_REGION_BLOCK; }

int find_free_inode(unsigned char *bitmap)
{
    /* TODO 1: Search bitmap indexes 1..31 and return INODE NUMBER. */
    /* Bit index i corresponds to inode number i + 1, so the scan starts at index 1:
       bitmap index 0 is inode 1, the root, which is never free. */
    /* TODO: STUDENT CODE START */
    for (int index = 1; index < TOTAL_INODES; index++) {
        if (!is_bit_set(bitmap, index)) {
            return index + 1;               /* inode number, not the index */
        }
    }
    /* TODO: STUDENT CODE END */
    return -1;
}

int find_free_data_block(unsigned char *bitmap)
{
    /* TODO 2: First-fit search; return ABSOLUTE data block number. */
    /* First fit over the 60 data-region blocks. Bitmap index 0 is absolute
       block 4, so the caller receives 4 + index, never the raw index. */
    /* TODO: STUDENT CODE START */
    for (int index = 0; index < DATA_BLOCKS; index++) {
        if (!is_bit_set(bitmap, index)) {
            return DATA_REGION_BLOCK + index;   /* absolute block number */
        }
    }
    /* TODO: STUDENT CODE END */
    return -1;
}

int filename_exists(FILE *image, const char *filename)
{
    dirent_t entry;
    /* TODO 3: Search root directory entries for filename. */
    /* The root directory is one block, so it holds 4096 / 64 = 64 entries.
       An entry is in use only when inode_no != 0. strncmp is bounded by the
       size of the name field so an image written by someone else, with a name
       that is not null-terminated, still cannot read past the entry. */
    /* TODO: STUDENT CODE START */
    for (int i = 0; i < BLOCK_SIZE / (int)sizeof(dirent_t); i++) {
        long position = ((long)ROOT_DATA_BLOCK * BLOCK_SIZE)
                      + ((long)i * (long)sizeof(dirent_t));

        if (fseek(image, position, SEEK_SET) != 0) { return 0; }
        if (fread(&entry, sizeof(entry), 1, image) != 1) { return 0; }

        if (entry.inode_no != 0
            && strncmp(entry.name, filename, sizeof(entry.name)) == 0) {
            return 1;                       /* duplicate name found */
        }
    }
    /* TODO: STUDENT CODE END */
    return 0;
}

int find_free_directory_entry(FILE *image)
{
    dirent_t entry;
    /* TODO 4: Search entries 2..63; free entry has inode_no == 0. */
    /* Entries 0 and 1 are permanently "." and "..", so a user file can only go
       in entry 2 or later. The first regular file therefore lands in entry 2. */
    /* TODO: STUDENT CODE START */
    for (int i = 2; i < BLOCK_SIZE / (int)sizeof(dirent_t); i++) {
        long position = ((long)ROOT_DATA_BLOCK * BLOCK_SIZE)
                      + ((long)i * (long)sizeof(dirent_t));

        if (fseek(image, position, SEEK_SET) != 0) { return -1; }
        if (fread(&entry, sizeof(entry), 1, image) != 1) { return -1; }

        if (entry.inode_no == 0) {
            return i;                       /* index of the free entry */
        }
    }
    /* TODO: STUDENT CODE END */
    return -1;
}

int main(int argc, char *argv[])
{
    char *image_name = NULL, *source_name = NULL;
    FILE *image, *source;
    superblock_t sb;
    unsigned char inode_bitmap[BLOCK_SIZE], data_bitmap[BLOCK_SIZE];
    inode_t new_inode, root_inode;
    dirent_t new_entry;
    long file_size;
    int required_blocks, free_inode;
    int allocated_blocks[MAX_DIRECT_BLOCKS] = {0};
    int directory_entry_index;

    if (argc != 5) { printf("Usage: %s --input <image> --file <file>\n", argv[0]); return 1; }
    if (strcmp(argv[1], "--input") != 0 || strcmp(argv[3], "--file") != 0) { printf("Error: invalid command-line arguments.\n"); return 1; }
    image_name = argv[2]; source_name = argv[4];

    image = fopen(image_name, "rb+");
    if (!image) { printf("Error: file-system image not found.\n"); return 1; }
    fseek(image, SUPERBLOCK_BLOCK * BLOCK_SIZE, SEEK_SET);
    if (fread(&sb, sizeof(sb), 1, image) != 1) { printf("Error: could not read superblock.\n"); fclose(image); return 1; }
    if (sb.magic != MAGIC_NUMBER) { printf("Error: invalid SimpleFS image.\n"); fclose(image); return 1; }

    source = fopen(source_name, "rb");
    if (!source) { printf("Error: source file not found.\n"); fclose(image); return 1; }
    fseek(source, 0, SEEK_END); file_size = ftell(source); rewind(source);
    if (file_size < 0) { printf("Error: could not determine source file size.\n"); fclose(source); fclose(image); return 1; }
    if (file_size > MAX_FILE_SIZE) { printf("Error: file is too large for SimpleFS.\n"); fclose(source); fclose(image); return 1; }

    /* The 59-byte name field must also hold a terminating null,
        so a name may be at most 58 characters. */
    if (strlen(source_name) > sizeof(new_entry.name) - 1) {
        printf("Error: file name is too long (maximum %d characters).\n",
               (int)(sizeof(new_entry.name) - 1));
        fclose(source); fclose(image); return 1;
    }

    /* TODO 5: Calculate required_blocks. Zero-byte file uses zero blocks. */
    /* The file size was already capped at MAX_FILE_SIZE,
        so this can never exceed MAX_DIRECT_BLOCKS. */
    /* TODO: STUDENT CODE START */
    required_blocks = (int)((file_size + BLOCK_SIZE - 1) / BLOCK_SIZE);
    /* TODO: STUDENT CODE END */

    if (filename_exists(image, source_name)) { printf("Error: file already exists in SimpleFS.\n"); fclose(source); fclose(image); return 1; }

    fseek(image, INODE_BITMAP_BLOCK * BLOCK_SIZE, SEEK_SET);

    if (fread(inode_bitmap, BLOCK_SIZE, 1, image) != 1) { printf("Error: could not read the inode bitmap.\n"); fclose(source); fclose(image); return 1; }
    free_inode = find_free_inode(inode_bitmap);
    if (free_inode == -1) { printf("Error: no free inode available.\n"); fclose(source); fclose(image); return 1; }

    fseek(image, DATA_BITMAP_BLOCK * BLOCK_SIZE, SEEK_SET);
    if (fread(data_bitmap, BLOCK_SIZE, 1, image) != 1) { printf("Error: could not read the data bitmap.\n"); fclose(source); fclose(image); return 1; }

    /* TODO 6: Allocate required data blocks and mark them in memory. */
    /* Allocating one block at a time. Each block is marked in the in-memory
       bitmap straight away, so the next call to find_free_data_block cannot
       hand out the same block twice. The bitmap is only written back to the
       image later, after every check has passed, so a failure here leaves the
       image exactly as it was. */
    /* TODO: STUDENT CODE START */
    for (int i = 0; i < required_blocks; i++) {
        int block = find_free_data_block(data_bitmap);
        if (block == -1) {
            printf("Error: not enough free data blocks in SimpleFS.\n");
            fclose(source); fclose(image); return 1;
        }
        allocated_blocks[i] = block;                            /* absolute block number */
        set_bit(data_bitmap, block - DATA_REGION_BLOCK);        /* bitmap index */
    }
    /* TODO: STUDENT CODE END */

    directory_entry_index = find_free_directory_entry(image);
    if (directory_entry_index == -1) { printf("Error: root directory is full.\n"); fclose(source); fclose(image); return 1; }

    /* TODO 7: Copy source contents into allocated blocks using zero-filled buffers. */
    /* One block at a time. The buffer is zeroed before every read, so when the
       last block is only partly filled its remaining bytes are written as zero,
       which is what the specification requires. The full 4096 bytes are always
       written, at absolute byte offset block * 4096. */
    /* TODO: STUDENT CODE START */
    for (int i = 0; i < required_blocks; i++) {
        unsigned char buffer[BLOCK_SIZE];
        size_t bytes_read;

        memset(buffer, 0, BLOCK_SIZE);
        bytes_read = fread(buffer, 1, BLOCK_SIZE, source);
        if (bytes_read == 0 && ferror(source)) {
            printf("Error: could not read the source file.\n");
            fclose(source); fclose(image); return 1;
        }

        if (fseek(image, (long)allocated_blocks[i] * BLOCK_SIZE, SEEK_SET) != 0
            || fwrite(buffer, BLOCK_SIZE, 1, image) != 1) {
            printf("Error: could not write file data to the image.\n");
            fclose(source); fclose(image); return 1;
        }
    }
    /* TODO: STUDENT CODE END */

    /* TODO 8: Initialize new file inode and its direct pointers. */
    memset(&new_inode, 0, sizeof(new_inode));
    /* TODO: STUDENT CODE START */
    new_inode.type  = TYPE_FILE;                /* 1 = regular file */
    new_inode.links = 1;
    new_inode.size  = (uint32_t)file_size;      /* the real size, not the allocated size:
                                                   a 5000-byte file has size 5000 even
                                                   though two blocks are reserved */
    for (int i = 0; i < MAX_DIRECT_BLOCKS; i++) {
        /* direct[] holds absolute block numbers; unused pointers stay 0. */
        new_inode.direct[i] = (i < required_blocks)
                            ? (uint32_t)allocated_blocks[i]
                            : 0;
    }
    /* TODO: STUDENT CODE END */
    fseek(image, inode_offset(free_inode), SEEK_SET);
    fwrite(&new_inode, sizeof(new_inode), 1, image);

    /* TODO 9: Mark allocated inode in inode bitmap. */
    /* Inode number -> bit index is a subtraction of 1: inode 2 is bit 1 */
    /* TODO: STUDENT CODE START */
    set_bit(inode_bitmap, free_inode - 1);
    /* TODO: STUDENT CODE END */
    fseek(image, INODE_BITMAP_BLOCK * BLOCK_SIZE, SEEK_SET);
    fwrite(inode_bitmap, BLOCK_SIZE, 1, image);
    fseek(image, DATA_BITMAP_BLOCK * BLOCK_SIZE, SEEK_SET);
    fwrite(data_bitmap, BLOCK_SIZE, 1, image);

    /* TODO 10: Create directory entry; ensure name is null-terminated. */
    memset(&new_entry, 0, sizeof(new_entry));
    /* This entry is what maps the name to the inode; the inode itself never
       stores a name. The length was already checked to be at most 58, and the
       struct was zeroed above, so the copied name is always null-terminated. */
    /* TODO: STUDENT CODE START */
    new_entry.inode_no = (uint32_t)free_inode;
    new_entry.type     = TYPE_FILE;
    memcpy(new_entry.name, source_name, strlen(source_name));
    /* TODO: STUDENT CODE END */
    {
        long pos = ((long)ROOT_DATA_BLOCK * BLOCK_SIZE) + ((long)directory_entry_index * sizeof(dirent_t));
        fseek(image, pos, SEEK_SET);
        fwrite(&new_entry, sizeof(new_entry), 1, image);
    }

    fseek(image, inode_offset(ROOT_INODE), SEEK_SET);
    if (fread(&root_inode, sizeof(root_inode), 1, image) != 1) { printf("Error: could not read the root inode.\n"); fclose(source); fclose(image); return 1; }

    /* TODO 11: Increase root_inode.size by sizeof(dirent_t). */
    /* The root directory just gained one 64-byte entry, so its size goes from
       128 to 192 after the first user file, and so on. */
    /* TODO: STUDENT CODE START */
    root_inode.size += (uint32_t)sizeof(dirent_t);
    /* TODO: STUDENT CODE END */
    fseek(image, inode_offset(ROOT_INODE), SEEK_SET);
    fwrite(&root_inode, sizeof(root_inode), 1, image);

    fclose(source); fclose(image);
    printf("%s added successfully to %s\n", source_name, image_name);
    return 0;
}
