#ifndef REPOS_H
#define REPOS_H

#include <string>
#include <vector>

using namespace std;

// A configured repository. A local one is a directory read in place; a remote
// one (http://, https://, ftp://) is mirrored through FETCHCMD: its index is
// kept in <root>/var/lib/tatami/repos/<name>/repo.solv and its packages are
// downloaded to <root>/var/cache/tatami/packages when they are installed.
struct repo_spec {
	string name;
	string url;             // as configured (file:// removed for local ones)
	bool remote;
	string dir;             // local: the directory; remote: where its index is cached
};

bool is_remote_url(const string& url);

// Reads <root>/etc/tatami/repos.conf and <root>/etc/tatami/repos.d/*.conf:
//   name=url        (name=/path, name=file:///path, name=https://host/dir)
// Missing, empty or unreadable files give an empty list. Throws runtime_error
// for a malformed line.
vector<repo_spec> read_repo_config(const string& root);

// Builds a repo_spec from a url or path (name is used for the cache of remote ones)
repo_spec make_repo_spec(const string& root, const string& name, const string& url);

// Runs 'fetchcmd' (FETCHCMD) to download 'url' to 'dest'. No shell is involved.
// The command's stderr is captured through a pipe and parsed for percentages
// (curl -# prints "######   45.2%"); with 'progress' and a terminal on stdout
// they are drawn as a bar, the raw text is never shown. If the command fails,
// its last message is part of the error. Throws runtime_error if the command
// cannot be run or fails; 'dest' is removed then.
void fetch_url(const string& fetchcmd, const string& url, const string& dest, bool progress = false);

// Looks for the progress of one piece of the command's stderr ("###  45.2%",
// as curl -# writes it). Returns the percentage 0..100, or -1 if it is not a
// progress line. Exposed for the tests.
int parse_progress(const string& segment);

#endif /* REPOS_H */
