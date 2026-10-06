#include "repos.h"
#include "hooks.h"
#include "paths.h"
#include "rootfs.h"
#include "util.h"
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <sys/wait.h>
#include <unistd.h>

bool is_remote_url(const string& url)
{
	return starts_with(url, "http://") || starts_with(url, "https://") || starts_with(url, "ftp://");
}

static bool valid_name(const string& n)
{
	return !n.empty() && n[0] != '.' && n[0] != '-' &&
		n.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-") == string::npos;
}

repo_spec make_repo_spec(const string& root, const string& name, const string& url)
{
	repo_spec r;
	r.name = name;
	r.url = url;
	r.remote = is_remote_url(url);

	if (r.remote) {
		for (size_t i = 0; i < url.size(); i++)
			if ((unsigned char)url[i] <= ' ' || url[i] == 0x7f)
				throw runtime_error("repository " + name + ": invalid character in URL " + url);
		while (r.url.size() > 1 && r.url[r.url.size() - 1] == '/')
			r.url.erase(r.url.size() - 1);
		r.dir = root_resolve(root, string(REPO_CACHE) + "/" + name);
	} else {
		if (starts_with(r.url, "file://"))
			r.url.erase(0, 7);
		if (r.url.find("://") != string::npos)
			throw runtime_error("repository " + name + ": unsupported URL " + url +
					    " (use a path, file://, http://, https:// or ftp://)");
		r.dir = r.url;
	}
	return r;
}

static void read_one(const string& root, const string& file, vector<repo_spec>& out)
{
	ifstream in(file.c_str());
	if (!in)
		return;                 // missing or unreadable: as if empty

	string line;
	unsigned int n = 0;
	while (getline(in, line)) {
		n++;
		line = trim(line);
		if (line.empty() || line[0] == '#')
			continue;

		const string where = file + ":" + itos(n) + ": ";
		const string::size_type eq = line.find('=');
		if (eq == string::npos)
			throw runtime_error(where + "expected name=url");
		const string name = trim(line.substr(0, eq));
		const string url = trim(line.substr(eq + 1));
		if (!valid_name(name))
			throw runtime_error(where + "invalid repository name '" + name + "'");
		if (url.empty())
			throw runtime_error(where + "repository " + name + " has no URL");
		for (size_t i = 0; i < out.size(); i++)
			if (out[i].name == name)
				throw runtime_error(where + "repository " + name + " is defined twice");
		out.push_back(make_repo_spec(root, name, url));
	}
}

vector<repo_spec> read_repo_config(const string& root)
{
	vector<repo_spec> result;
	read_one(root, root_resolve(root, REPOS_CONF), result);

	DIR* d = opendir(root_resolve(root, REPOS_DIR).c_str());
	if (d) {
		vector<string> names;
		struct dirent* de;
		while ((de = readdir(d))) {
			const string f = de->d_name;
			if (ends_with(f, ".conf") && f.size() > 5 && f[0] != '.')
				names.push_back(f);
		}
		closedir(d);
		sort(names.begin(), names.end());
		for (size_t i = 0; i < names.size(); i++)
			read_one(root, root_resolve(root, string(REPOS_DIR) + "/" + names[i]), result);
	}
	return result;
}

int parse_progress(const string& segment)
{
	const string t = trim(segment);
	if (t.empty() || t[t.size() - 1] != '%')
		return -1;

	string::size_type i = t.size() - 1;
	while (i > 0 && (isdigit((unsigned char)t[i - 1]) || t[i - 1] == '.'))
		i--;
	const string number = t.substr(i, t.size() - 1 - i);
	if (number.empty())
		return -1;
	// only the bar characters may precede the number: anything else is a message
	if (t.substr(0, i).find_first_not_of("#=->* \t") != string::npos)
		return -1;

	const double v = atof(number.c_str());
	return v < 0 ? 0 : v > 100 ? 100 : (int)v;
}

namespace {

const int BAR_WIDTH = 30;

void draw_bar(int percent)
{
	const int filled = percent * BAR_WIDTH / 100;
	string bar = "[";
	for (int i = 0; i < BAR_WIDTH; i++)
		bar += i < filled ? '=' : (i == filled && percent < 100 ? '>' : ' ');
	bar += "] ";
	if (percent < 100)
		bar += percent < 10 ? "  " : " ";
	bar += itos(percent) + "%";
	cout << "\r  " << bar << flush;
}

// Reads the child's stderr to the end. Complete pieces (ended by \r or \n) and the
// growing last piece are looked at for progress; the rest is kept as the message.
struct progress_reader {
	bool show;
	int last;               // last percentage drawn, -1: none
	string pending;
	string message;

	explicit progress_reader(bool s) : show(s), last(-1) {}

	void note(int percent) {
		if (percent < 0 || percent == last)
			return;
		last = percent;
		if (show)
			draw_bar(percent);
	}

	void feed(const char* data, size_t n) {
		for (size_t i = 0; i < n; i++) {
			const char c = data[i];
			if (c == '\r' || c == '\n') {
				finish_piece();
			} else if (pending.size() < 4096) {
				pending += c;
			}
		}
		note(parse_progress(pending));
	}

	void finish_piece() {
		const string t = trim(pending);
		if (!t.empty()) {
			const int p = parse_progress(t);
			if (p >= 0)
				note(p);
			else
				message = t.substr(0, 200);
		}
		pending.clear();
	}
};

}

void fetch_url(const string& fetchcmd, const string& url, const string& dest, bool progress)
{
	if (fetchcmd.find("%URL%") == string::npos || fetchcmd.find("%DEST%") == string::npos)
		throw runtime_error("FETCHCMD must contain %URL% and %DEST%");
	if (url.empty() || url[0] == '-')
		throw runtime_error("refusing to fetch '" + url + "'");

	vector<string> words = split_command(fetchcmd);
	if (words.empty())
		throw runtime_error("FETCHCMD is empty");
	for (size_t i = 0; i < words.size(); i++) {
		string::size_type pos;
		while ((pos = words[i].find("%URL%")) != string::npos)
			words[i].replace(pos, 5, url);
		while ((pos = words[i].find("%DEST%")) != string::npos)
			words[i].replace(pos, 6, dest);
	}

	vector<char*> argv;
	for (size_t i = 0; i < words.size(); i++)
		argv.push_back(const_cast<char*>(words[i].c_str()));
	argv.push_back(0);

	// The child's stderr goes through a pipe that we read; its stdin and stdout
	// are /dev/null so that the only thing the user sees is our own bar.
	int fds[2];
	if (pipe(fds) == -1)
		throw runtime_error_with_errno("could not create a pipe");

	cout.flush();
	cerr.flush();
	pid_t pid = fork();
	if (pid == -1) {
		const int e = errno;
		close(fds[0]);
		close(fds[1]);
		throw runtime_error_with_errno("could not run FETCHCMD", e);
	}
	if (pid == 0) {
		close(fds[0]);
		const int null = open("/dev/null", O_RDWR);
		if (null != -1) {
			dup2(null, STDIN_FILENO);
			dup2(null, STDOUT_FILENO);
			if (null > STDERR_FILENO)
				close(null);
		}
		dup2(fds[1], STDERR_FILENO);
		if (fds[1] != STDERR_FILENO)
			close(fds[1]);
		execvp(argv[0], &argv[0]);
		const string msg = string("could not run ") + argv[0] + ": " + strerror(errno) + "\n";
		if (write(STDERR_FILENO, msg.data(), msg.size()) < 0) {}
		_exit(127);
	}
	close(fds[1]);

	progress_reader reader(progress && isatty(STDOUT_FILENO));
	char buf[1024];
	for (;;) {
		const ssize_t n = read(fds[0], buf, sizeof buf);
		if (n > 0)
			reader.feed(buf, (size_t)n);
		else if (n == 0 || errno != EINTR)
			break;
	}
	close(fds[0]);
	reader.finish_piece();

	int status = 0;
	while (waitpid(pid, &status, 0) == -1 && errno == EINTR)
		;
	const bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;

	if (reader.show && reader.last >= 0) {
		if (ok)
			draw_bar(100);
		cout << endl;
	}

	if (!ok) {
		unlink(dest.c_str());
		string why = WIFEXITED(status) ? "exit status " + itos(WEXITSTATUS(status)) : string("was killed");
		if (!reader.message.empty())
			why += ": " + reader.message;
		throw runtime_error("downloading " + url + " failed (FETCHCMD " + why + ")");
	}
	if (!file_exists(dest) || file_empty(dest)) {
		unlink(dest.c_str());
		throw runtime_error("downloading " + url + " produced no file");
	}
}
