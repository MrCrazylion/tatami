#ifndef PACK_H
#define PACK_H

// Entry point of  tatami pack [-z <compression>] <meta-file> <source-dir> <output>
//
// Creates a package archive with libarchive itself, so building a package needs
// no tar or compression program on the host: .META (from <meta-file>) first,
// then everything below <source-dir>, sorted, with numeric owners. The
// compression is gz, zst, xz, bz2, lz4, lzma or none (default zst).
int pack_main(int argc, char** argv);

#endif /* PACK_H */
