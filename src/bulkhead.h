#ifndef BULKHEAD_H
#define BULKHEAD_H

#include <string>
#include <vector>

using namespace std;

#define BULKHEAD_EXIT_USAGE     2       // bad command line
#define BULKHEAD_EXIT_LAUNCH    255     // fork() or exec of bwrap failed

// The full bwrap command line (argv[0] included) that runs 'command' in the
// isolated build environment:
//   - read-only host root, fresh /dev and /proc (so the host's processes are
//     not visible), writable tmpfs /tmp
//   - /home and /root replaced by empty tmpfs: no user data is readable and
//     nothing can be written there. Host paths the build needs that live in
//     there (the recipe, the sources) are mapped back read-only through
//     'ro_paths', after the tmpfs
//   - 'destdir' (a host directory) mapped to /tmp/destdir (inside the tmpfs,
//     so no mount point has to exist on the read-only root)
//   - no network, own PID namespace, killed together with its parent
vector<string> bulkhead_args(const string& destdir, const vector<string>& ro_paths,
			     const vector<string>& command);

// Runs the command line with fork/execvp/waitpid and returns the exit status
// to use: the child's exit status, 128 + signal if it was killed by one, or
// BULKHEAD_EXIT_LAUNCH if bwrap could not be started.
int bulkhead_run(const vector<string>& args);

// Entry point of "tatami bulkhead <host_destdir> -- <command> [args...]"
int bulkhead_main(int argc, char** argv);

#endif /* BULKHEAD_H */
