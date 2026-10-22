#ifndef PACK_H
#define PACK_H

#include <string>

// Writes a package archive with libarchive itself, so building a package needs no tar or
// compression program on the host: <meta_file> is stored as .META, first, then everything
// below <source_dir>, sorted, with numeric owners. compression is gz, zst, xz, bz2, lz4, lzma
// or none. Throws std::runtime_error; the caller removes a partly written <output>.
void pack_archive(const std::string& compression, const std::string& meta_file,
		  const std::string& source_dir, const std::string& output);

#endif /* PACK_H */
