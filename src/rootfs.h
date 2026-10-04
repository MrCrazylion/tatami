#ifndef ROOTFS_H
#define ROOTFS_H

#include <string>

using namespace std;

// Resolves 'rel', a path relative to the installation root 'root', to the
// absolute path to use on the host, treating the root like a chroot:
//   - symbolic links in the directories of the path are followed *inside* the
//     root: a relative target (/lib -> usr/lib) stays below the link, an
//     absolute one (/lib -> /usr/lib) is taken relative to the root and not
//     to the host, and ".." never climbs above the root;
//   - the last component is not resolved (the link itself is what is meant);
//   - components that do not exist yet are kept as they are.
// So no operation on the result can reach outside the root, whatever the
// symlinks in it look like. 'root' is absolute, with or without a trailing '/'
// ("" or "/" is the real root). Throws on symlink loops.
string root_resolve(const string& root, const string& rel);

#endif /* ROOTFS_H */
