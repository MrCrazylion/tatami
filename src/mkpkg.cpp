//
//  tatami-mkpkg - build a package from a Tatamifile inside a bubblewrap sandbox.
//
//  The recipe is read by a small parser of its own (the shell is never run on the
//  host); the build() and package() bodies are run by /bin/sh inside the sandbox,
//  whose root is a read-only masterdir. The workspace /tmp/<random> is bound at
//  /build and deleted on every way out of the program.
//
//  Tatamifile syntax understood here (a strict subset of shell):
//      # Description: a short text
//      name=zlib            version=1.3.2        release=1       # release is optional
//      arch=x86_64                                               # or noarch; required
//      source=(zlib-1.3.2.tar.gz https://example.org/$name-$version.tar.gz)
//      depends=(glibc "foo >= 1.2" "a | b")
//      build() { ... }      package() { ... }    # package() is optional
//  Any other NAME=value or NAME=(...) assignment (makedepends, conflicts, replaces,
//  ...) is skipped without being interpreted. Anything else is a syntax error.
//
//  The package is <name>_<version>[-<release>]_<arch>.<extension>, written with libarchive
//  (the extension and the compression are fixed when tatami is built; -z overrides the
//  compression), exactly as the former shell script named and compressed it.
//

#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <archive.h>
#include <archive_entry.h>

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "pack.h"

namespace fs = std::filesystem;
using std::string;
using std::vector;

namespace {

const char* const DEFAULT_MASTERDIR = "/var/lib/tatami/masterdir";

// Fixed when tatami is built (make PKG_EXT=... PKG_COMPRESSION=...); there is no run-time setting
#ifndef VERSION
#define VERSION "unknown"
#endif
#ifndef DEFAULT_PKG_EXT
#define DEFAULT_PKG_EXT "tar.pkg"
#endif
#ifndef DEFAULT_PKG_COMPRESSION
#define DEFAULT_PKG_COMPRESSION "zst"
#endif

// An error printed as it is, without the program name (the message of the former script)
class raw_error : public std::runtime_error {
public:
	explicit raw_error(const string& what) : std::runtime_error(what) {}
};

//
// The recipe
//

struct recipe {
	string name, version, release, arch, description;
	vector<string> source, depends;
	string build, package;                  // the bodies of build() and package()
	bool has_package = false;
};

class parser {
public:
	explicit parser(string text) : s_(std::move(text)) {}

	recipe parse()
	{
		recipe r;
		bool has_build = false;

		for (;;) {
			skip_blank();
			if (p_ >= s_.size())
				break;
			const string id = identifier();
			if (peek() == '=') {
				p_++;
				assignment(id, r);
			} else {
				skip_space();
				if (peek() != '(')
					fail("unsupported statement '" + id + "' (only assignments and functions are allowed)");
				p_++;
				skip_space();
				if (peek() != ')')
					fail("expected ')' after '" + id + "('");
				p_++;
				skip_blank();
				if (peek() != '{')
					fail("expected '{' after '" + id + "()'");
				p_++;
				const string text = body();
				if (id == "build") {
					r.build = text;
					has_build = true;
				} else if (id == "package") {
					r.package = text;
					r.has_package = true;
				}                               // any other function is skipped
			}
		}

		r.description = description(s_);
		if (r.name.empty())
			throw std::runtime_error("recipe does not set 'name'");
		if (r.version.empty())
			throw std::runtime_error("recipe does not set 'version'");
		if (r.arch.empty())
			throw raw_error("Error: arch is not defined in Tatamifile");
		if (!has_build)
			throw std::runtime_error("recipe does not define build()");
		for (const vector<string>* list : { &r.depends })
			for (const string& item : *list)
				if (item.find_first_of(",\n") != string::npos)
					throw std::runtime_error("relation '" + item + "' must not contain a comma or newline "
								 "(use one array element per relation)");
		const string chars = r.name + r.version + r.release;
		if (chars.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.~:-") != string::npos)
			throw std::runtime_error("name, version and release may only contain letters, digits and + . ~ : - "
						 "('_' separates name and version in file names)");
		if (!isalnum((unsigned char)r.name[0]))
			throw std::runtime_error("name must start with a letter or digit");
		return r;
	}

private:
	string s_;
	size_t p_ = 0;
	std::map<string, string> vars_;         // scalars seen so far, for $name and ${name}

	char peek() const { return p_ < s_.size() ? s_[p_] : '\0'; }

	[[noreturn]] void fail(const string& what) const
	{
		int line = 1;
		for (size_t i = 0; i < p_ && i < s_.size(); i++)
			if (s_[i] == '\n')
				line++;
		throw std::runtime_error("Tatamifile line " + std::to_string(line) + ": " + what);
	}

	// the first "# Description: text" line of the recipe
	static string description(const string& text)
	{
		std::istringstream in(text);
		string line;
		while (std::getline(in, line)) {
			if (line.empty() || line[0] != '#')
				continue;
			size_t i = 1;
			while (i < line.size() && line[i] == ' ')
				i++;
			if (line.compare(i, 12, "Description:") == 0) {
				size_t from = i + 12;
				while (from < line.size() && line[from] == ' ')
					from++;
				size_t to = line.size();
				while (to > from && (line[to - 1] == ' ' || line[to - 1] == '\r'))
					to--;
				return line.substr(from, to - from);
			}
		}
		return "";
	}

	static bool blank(char c) { return c == ' ' || c == '\t' || c == '\r'; }

	void skip_space()
	{
		while (blank(peek()))
			p_++;
	}

	void skip_comment()
	{
		while (p_ < s_.size() && s_[p_] != '\n')
			p_++;
	}

	// blanks, newlines, semicolons and comments between statements
	void skip_blank()
	{
		while (p_ < s_.size()) {
			const char c = s_[p_];
			if (blank(c) || c == '\n' || c == ';')
				p_++;
			else if (c == '#')
				skip_comment();
			else
				break;
		}
	}

	string identifier()
	{
		const size_t start = p_;
		if (p_ < s_.size() && (isalpha((unsigned char)s_[p_]) || s_[p_] == '_'))
			while (p_ < s_.size() && (isalnum((unsigned char)s_[p_]) || s_[p_] == '_'))
				p_++;
		if (p_ == start)
			fail(string("unexpected character '") + peek() + "'");
		return s_.substr(start, p_ - start);
	}

	// $name and ${name}; a variable that was not set is an error, anything else stays as written
	void expand(const string& in, string& out)
	{
		for (size_t i = 0; i < in.size(); i++) {
			if (in[i] != '$' || i + 1 >= in.size()) {
				out += in[i];
				continue;
			}
			size_t j = i + 1;
			const bool braced = in[j] == '{';
			if (braced)
				j++;
			const size_t from = j;
			while (j < in.size() && (isalnum((unsigned char)in[j]) || in[j] == '_'))
				j++;
			if (j == from || (braced && (j >= in.size() || in[j] != '}'))) {
				out += in[i];
				continue;
			}
			const string key = in.substr(from, j - from);
			const auto v = vars_.find(key);
			if (v == vars_.end())
				fail("the variable $" + key + " is not set before its use");
			out += v->second;
			i = braced ? j : j - 1;
		}
	}

	// One shell word: quotes group, a backslash escapes, $name is expanded (not inside '...')
	string word()
	{
		string out;
		for (;;) {
			const char c = peek();
			if (p_ >= s_.size() || blank(c) || c == '\n' || c == ';' || c == ')' || c == '(' ||
			    c == '&' || c == '|' || c == '<' || c == '>')
				break;
			if (c == '\'') {
				const size_t end = s_.find('\'', p_ + 1);
				if (end == string::npos)
					fail("unterminated quote '");
				out.append(s_, p_ + 1, end - p_ - 1);
				p_ = end + 1;
			} else if (c == '"') {
				string raw;
				p_++;
				for (;;) {
					if (p_ >= s_.size())
						fail("unterminated quote \"");
					const char d = s_[p_++];
					if (d == '"')
						break;
					if (d == '\\' && p_ < s_.size()) {
						const char e = s_[p_];
						if (e == '"' || e == '\\' || e == '$' || e == '`') {
							raw += (e == '$') ? string("\\$") : string(1, e);
							p_++;
							continue;
						}
						if (e == '\n') {
							p_++;
							continue;
						}
					}
					raw += d;
				}
				expand_unescaped(raw, out);
			} else if (c == '\\' && p_ + 1 < s_.size()) {
				if (s_[p_ + 1] != '\n')
					out += s_[p_ + 1];
				p_ += 2;
			} else {
				const size_t start = p_;
				while (p_ < s_.size() && !blank(s_[p_]) && !strchr("\n;()&|<>'\"\\", s_[p_]))
					p_++;
				expand(s_.substr(start, p_ - start), out);
			}
		}
		return out;
	}

	// like expand(), but "\$" stays a literal dollar
	void expand_unescaped(const string& raw, string& out)
	{
		string piece;
		for (size_t i = 0; i < raw.size(); i++) {
			if (raw[i] == '\\' && i + 1 < raw.size() && raw[i + 1] == '$') {
				expand(piece, out);
				piece.clear();
				out += '$';
				i++;
			} else {
				piece += raw[i];
			}
		}
		expand(piece, out);
	}

	vector<string> array()
	{
		vector<string> items;
		for (;;) {
			// blanks, newlines and comments between the items
			while (p_ < s_.size() && (blank(s_[p_]) || s_[p_] == '\n' || s_[p_] == '#')) {
				if (s_[p_] == '#')
					skip_comment();
				else
					p_++;
			}
			if (p_ >= s_.size())
				fail("unterminated array: missing ')'");
			if (s_[p_] == ')') {
				p_++;
				return items;
			}
			const size_t before = p_;
			items.push_back(word());
			if (p_ == before)
				fail(string("unexpected character '") + peek() + "' in an array");
		}
	}

	void assignment(const string& id, recipe& r)
	{
		vector<string> values;
		bool is_array = false;
		if (peek() == '(') {
			p_++;
			values = array();
			is_array = true;
		} else if (p_ >= s_.size() || blank(peek()) || peek() == '\n' || peek() == ';' || peek() == '#') {
			values.push_back("");           // NAME=
		} else {
			values.push_back(word());
		}
		skip_space();
		if (peek() == '#')
			skip_comment();
		if (p_ < s_.size() && peek() != '\n' && peek() != ';')
			fail("unexpected text after the value of " + id);

		// makedepends, conflicts, replaces and everything else unknown end up here, unread
		if (id == "name" || id == "version" || id == "release" || id == "arch") {
			if (is_array)
				fail(id + " must be a single word, not an array");
			(id == "name" ? r.name : id == "version" ? r.version : id == "release" ? r.release : r.arch) = values[0];
			vars_[id] = values[0];
		} else if (id == "source") {
			r.source = values;
		} else if (id == "depends") {
			r.depends = values;
		} else if (!is_array) {
			vars_[id] = values[0];
		}
	}

	// the text between '{' (already consumed) and its matching '}'
	string body()
	{
		const size_t start = p_;
		int depth = 1;
		while (p_ < s_.size()) {
			const char c = s_[p_];
			if (c == '\'') {
				const size_t end = s_.find('\'', p_ + 1);
				if (end == string::npos)
					break;
				p_ = end + 1;
				continue;
			}
			if (c == '"') {
				p_++;
				while (p_ < s_.size() && s_[p_] != '"')
					p_ += (s_[p_] == '\\') ? 2 : 1;
				p_++;
				continue;
			}
			if (c == '\\') {
				p_ += 2;
				continue;
			}
			if (c == '#' && (p_ == 0 || strchr(" \t\n;&|(", s_[p_ - 1]))) {
				skip_comment();
				continue;
			}
			if (c == '{')
				depth++;
			else if (c == '}' && --depth == 0) {
				const string text = s_.substr(start, p_ - start);
				p_++;
				return text;
			}
			p_++;
		}
		p_ = std::min(p_, s_.size());
		fail("a function body is not closed: missing '}'");
	}
};

recipe read_recipe(const string& file)
{
	std::ifstream in(file, std::ios::binary);
	if (!in)
		throw std::runtime_error("cannot read " + file);
	std::ostringstream text;
	text << in.rdbuf();
	return parser(text.str()).parse();
}

//
// The workspace: /tmp/<hash>, created here, deleted whatever happens
//

// 24 characters from a-z0-9, drawn from /dev/urandom without modulo bias
string random_hash(size_t length)
{
	static const char alphabet[] = "abcdefghijklmnopqrstuvwxyz0123456789";
	const int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
	if (fd == -1)
		throw std::runtime_error(string("cannot open /dev/urandom: ") + strerror(errno));
	string out;
	while (out.size() < length) {
		unsigned char buf[64];
		const ssize_t n = read(fd, buf, sizeof buf);
		if (n <= 0) {
			if (n == -1 && errno == EINTR)
				continue;
			close(fd);
			throw std::runtime_error("cannot read /dev/urandom");
		}
		for (ssize_t i = 0; i < n && out.size() < length; i++)
			if (buf[i] < 252)               // 252 = 7 * 36: every character equally likely
				out += alphabet[buf[i] % 36];
	}
	close(fd);
	return out;
}

bool is_workspace_path(const string& p)
{
	if (p.compare(0, 5, "/tmp/") != 0)
		return false;
	const string h = p.substr(5);
	return h.size() >= 16 && h.size() <= 32 &&
	       h.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789") == string::npos;
}

// rm -rf: directories the build made read-only are made writable first (no symlink is followed)
void make_writable(const string& dir)
{
	chmod(dir.c_str(), 0700);
	DIR* d = opendir(dir.c_str());
	if (!d)
		return;
	while (const dirent* e = readdir(d)) {
		const string name = e->d_name;
		if (name == "." || name == "..")
			continue;
		const string child = dir + "/" + name;
		struct stat st;
		if (lstat(child.c_str(), &st) == 0 && S_ISDIR(st.st_mode))
			make_writable(child);
	}
	closedir(d);
}

class workspace {
public:
	workspace()
	{
		for (int attempt = 0; attempt < 16; attempt++) {
			const string candidate = "/tmp/" + random_hash(24);
			if (mkdir(candidate.c_str(), 0700) == 0) {
				path_ = candidate;
				break;
			}
			if (errno != EEXIST)             // an existing name is never reused
				throw std::runtime_error("cannot create " + candidate + ": " + strerror(errno));
		}
		if (path_.empty())
			throw std::runtime_error("cannot find an unused name below /tmp");
		for (const char* sub : { "/src", "/pkg" })              // sources, and the package root
			if (mkdir((path_ + sub).c_str(), 0755) != 0) {
				const string why = strerror(errno);
				remove();
				throw std::runtime_error("cannot create " + path_ + sub + ": " + why);
			}
	}
	~workspace() { remove(); }
	workspace(const workspace&) = delete;
	workspace& operator=(const workspace&) = delete;

	const string& path() const { return path_; }

private:
	string path_;

	void remove() noexcept
	{
		if (path_.empty())
			return;
		try {
			if (!is_workspace_path(path_)) {            // never run a recursive delete on anything else
				std::cerr << "tatami-mkpkg: refusing to delete " << path_ << "\n";
			} else {
				make_writable(path_);
				std::error_code ec;
				fs::remove_all(path_, ec);
				if (ec)
					std::cerr << "tatami-mkpkg: warning: could not remove " << path_ << ": " << ec.message() << "\n";
			}
		} catch (...) {
		}
		path_.clear();
	}
};

//
// Running bwrap
//

volatile sig_atomic_t g_signal = 0;

void on_signal(int sig) { g_signal = sig; }

void install_signal_handlers()
{
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_signal;              // no SA_RESTART: waitpid() must return
	sigemptyset(&sa.sa_mask);
	for (int sig : { SIGINT, SIGTERM, SIGHUP })
		sigaction(sig, &sa, nullptr);
}

// fork + execvp; returns the exit status of the program
int run_command(const vector<string>& args, bool quiet = false)
{
	std::cout.flush();
	std::cerr.flush();

	int err[2];
	if (pipe2(err, O_CLOEXEC) == -1)
		throw std::runtime_error(string("pipe: ") + strerror(errno));

	const pid_t pid = fork();
	if (pid == -1) {
		const int e = errno;
		close(err[0]);
		close(err[1]);
		throw std::runtime_error(string("fork: ") + strerror(e));
	}
	if (pid == 0) {
		if (quiet) {                        // the program's standard output is not wanted
			const int null = open("/dev/null", O_WRONLY);
			if (null != -1)
				dup2(null, STDOUT_FILENO);
		}
		vector<char*> argv;
		for (const string& a : args)
			argv.push_back(const_cast<char*>(a.c_str()));
		argv.push_back(nullptr);
		execvp(argv[0], argv.data());
		const int e = errno;
		(void)!write(err[1], &e, sizeof e);
		_exit(127);
	}

	close(err[1]);
	int exec_errno = 0;
	ssize_t n;
	while ((n = read(err[0], &exec_errno, sizeof exec_errno)) == -1 && errno == EINTR) {
	}
	close(err[0]);

	bool forwarded = false;
	int status = 0;
	while (waitpid(pid, &status, 0) == -1) {
		if (errno != EINTR)
			throw std::runtime_error(string("waitpid: ") + strerror(errno));
		if (g_signal && !forwarded) {       // bwrap runs in its own session: pass the signal on
			kill(pid, SIGTERM);
			forwarded = true;
		}
	}
	if (n == (ssize_t)sizeof exec_errno)
		throw std::runtime_error("cannot run " + args[0] + ": " + strerror(exec_errno) +
					 (exec_errno == ENOENT && args[0] == "bwrap" ? " (is bubblewrap installed?)" : ""));
	if (g_signal)
		throw std::runtime_error(string("interrupted by signal ") + std::to_string((int)g_signal));
	return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

// bwrap cannot create a mount point on a read-only root, so they must exist in the masterdir
void prepare_masterdir(const string& masterdir)
{
	struct stat st;
	if (stat(masterdir.c_str(), &st) != 0 || !S_ISDIR(st.st_mode))
		throw std::runtime_error("the masterdir " + masterdir + " does not exist (see 'make bootstrap-env')");
	for (const char* d : { "dev", "proc", "tmp", "build" }) {
		std::error_code ec;
		fs::create_directories(masterdir + "/" + d, ec);
		if (ec)
			throw std::runtime_error("cannot create " + masterdir + "/" + d + ": " + ec.message());
	}
}

// What /bin/sh runs: the two functions as written, then the calls. A failing command stops it.
string build_script(const recipe& r)
{
	string s = "set -e\nbuild() {" + r.build + "\n}\n";
	if (r.has_package)
		s += "package() {" + r.package + "\n}\n";
	s += "build\n";
	if (r.has_package)
		s += "package\n";
	return s;
}

//
// Package name and compression: as the former script did
//

bool ends_with(const string& s, const string& suffix)
{
	return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

string lowercase(string s)
{
	for (char& c : s)
		c = (char)tolower((unsigned char)c);
	return s;
}

struct naming {
	string compression;     // gz, xz, zst, bz2, lz4, lzma or none
	string extension;       // tar.pkg by default
};

// -z, then what the build-time extension ends in, then the build-time default; the extension
// is the build-time one, or tar.<compression> when that is empty
naming choose_naming(const string& compression_option)
{
	const string ext = DEFAULT_PKG_EXT;
	naming n;
	n.compression = compression_option;
	if (n.compression.empty()) {
		if (ends_with(ext, "gz")) n.compression = "gz";
		else if (ends_with(ext, "xz")) n.compression = "xz";
		else if (ends_with(ext, "zst")) n.compression = "zst";
		else if (ends_with(ext, "bz2")) n.compression = "bz2";
		else if (ends_with(ext, "lz4")) n.compression = "lz4";
		else if (ends_with(ext, "lzma")) n.compression = "lzma";
		else n.compression = DEFAULT_PKG_COMPRESSION;
	}
	static const char* const known[] = { "gz", "xz", "zst", "bz2", "lz4", "lzma", "none" };
	if (std::find(std::begin(known), std::end(known), n.compression) == std::end(known))
		throw std::runtime_error("invalid compression '" + n.compression + "' (use gz, zst, xz, bz2, lz4, lzma or none)");
	if (!ext.empty())
		n.extension = ext;
	else if (n.compression == "none")
		n.extension = "tar";
	else
		n.extension = "tar." + n.compression;
	return n;
}

// <name>_<version>[-<release>]_<arch>.<extension>; the version and the architecture as they are in the package
struct identity {
	string version, arch, file;
};

identity package_identity(const recipe& r, const naming& n)
{
	identity id;
	id.version = r.release.empty() ? r.version : r.version + "-" + r.release;
	id.arch = r.arch;
	const string lower = lowercase(id.arch);
	if (lower == "noarch" || lower == "all" || lower == "any")      // not tied to an architecture
		id.arch = "noarch";
	if (id.arch.empty() || id.arch.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != string::npos)
		throw std::runtime_error("invalid arch '" + id.arch + "'");
	id.file = r.name + "_" + id.version + "_" + id.arch + "." + n.extension;
	return id;
}

//
// Sources: fetched next to the recipe, verified, unpacked into the workspace
//

string base_name(const string& source)
{
	const string file = source.substr(source.rfind('/') == string::npos ? 0 : source.rfind('/') + 1);
	if (file.empty() || file == "." || file == ".." || file.find_first_of("\n\\") != string::npos)
		throw std::runtime_error("invalid source '" + source + "'");
	return file;
}

void collect_sources(const recipe& r, const fs::path& dir)
{
	std::cerr << "=======> Collecting sources\n";
	for (const string& s : r.source) {
		const string file = base_name(s);
		const fs::path path = dir / file;
		std::error_code ec;
		if (s.find("://") != string::npos && !fs::exists(path, ec)) {
			std::cerr << "=======> Downloading " << s << "\n";
			const fs::path part = dir / (file + ".part");
			if (run_command({ "curl", "-fL", "--retry", "3", "-o", part.string(), s }) != 0) {
				fs::remove(part, ec);
				throw std::runtime_error("download of " + s + " failed");
			}
			fs::rename(part, path, ec);
			if (ec)
				throw std::runtime_error("cannot store " + path.string() + ": " + ec.message());
		}
		if (!fs::exists(path, ec))
			throw std::runtime_error("source '" + file + "' not found");
	}

	// .md5sum next to the recipe: every source needs a line, and md5sum checks them
	const fs::path sums = dir / ".md5sum";
	std::error_code ec;
	if (r.source.empty() || !fs::is_regular_file(sums, ec))
		return;
	std::cerr << "=======> Checking md5sum\n";
	std::ifstream in(sums);
	std::map<string, string> hashes;
	string line;
	while (std::getline(in, line)) {
		std::istringstream fields(line);
		string hash, name;
		if (!(fields >> hash >> name))
			continue;
		if (!name.empty() && name[0] == '*')
			name.erase(0, 1);
		hashes.emplace(name, hash);
	}
	string input;
	for (const string& s : r.source) {
		const string file = base_name(s);
		const auto h = hashes.find(file);
		if (h == hashes.end())
			throw std::runtime_error("no checksum for " + file);
		input += h->second + "  " + (dir / file).string() + "\n";
	}
	std::cout.flush();
	std::cerr.flush();
	FILE* md5 = popen("md5sum -c --quiet -", "w");
	if (!md5)
		throw std::runtime_error("cannot run md5sum");
	fputs(input.c_str(), md5);
	if (pclose(md5) != 0)
		throw std::runtime_error("md5sum verification failed");
}

struct reader_closer { void operator()(struct archive* a) const { archive_read_free(a); } };
struct disk_closer { void operator()(struct archive* a) const { archive_write_free(a); } };

// libarchive unpacks tar and zip files below dest: no entry can leave it (absolute and ".." names are refused,
// and no symbolic link already extracted is followed out of it)
void extract_archive(const string& file, const string& dest)
{
	std::unique_ptr<struct archive, reader_closer> in(archive_read_new());
	std::unique_ptr<struct archive, disk_closer> out(archive_write_disk_new());
	archive_read_support_format_all(in.get());
	archive_read_support_filter_all(in.get());
	archive_write_disk_set_options(out.get(), ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM |
				       ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT);
	if (archive_read_open_filename(in.get(), file.c_str(), 65536) != ARCHIVE_OK)
		throw std::runtime_error("could not unpack " + file + ": " + archive_error_string(in.get()));

	struct archive_entry* e;
	int rc;
	while ((rc = archive_read_next_header(in.get(), &e)) != ARCHIVE_EOF) {
		if (rc < ARCHIVE_WARN)
			throw std::runtime_error("could not unpack " + file + ": " + archive_error_string(in.get()));
		const char* name = archive_entry_pathname(e);
		if (!name || !*name)
			continue;
		const string path = name;
		if (path[0] == '/' || path == ".." || path.compare(0, 3, "../") == 0 || path.find("/../") != string::npos ||
		    ends_with(path, "/.."))
			throw std::runtime_error("refusing to unpack " + file + ": unsafe path '" + path + "'");
		archive_entry_copy_pathname(e, (dest + "/" + path).c_str());
		if (const char* link = archive_entry_hardlink(e)) {
			const string target = link;
			if (target.empty() || target[0] == '/' || target.find("..") != string::npos)
				throw std::runtime_error("refusing to unpack " + file + ": unsafe link '" + target + "'");
			archive_entry_copy_hardlink(e, (dest + "/" + target).c_str());
		}
		if (archive_write_header(out.get(), e) != ARCHIVE_OK)
			throw std::runtime_error("could not unpack " + file + ": " + archive_error_string(out.get()));
		const void* buf;
		size_t size;
		la_int64_t offset;
		while ((rc = archive_read_data_block(in.get(), &buf, &size, &offset)) == ARCHIVE_OK)
			if (archive_write_data_block(out.get(), buf, size, offset) != ARCHIVE_OK)
				throw std::runtime_error("could not unpack " + file + ": " + archive_error_string(out.get()));
		if (rc != ARCHIVE_EOF)
			throw std::runtime_error("could not unpack " + file + ": " + archive_error_string(in.get()));
		if (archive_write_finish_entry(out.get()) != ARCHIVE_OK)
			throw std::runtime_error("could not unpack " + file + ": " + archive_error_string(out.get()));
	}
}

void unpack_sources(const recipe& r, const fs::path& recipe_dir, const string& dest)
{
	std::cerr << "=======> Unpacking sources\n";
	static const char* const archives[] = { ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz",
						".tar.zst", ".tar.lz", ".zip" };
	for (const string& s : r.source) {
		const string file = base_name(s);
		const fs::path path = recipe_dir / file;
		bool is_archive = false;
		for (const char* suffix : archives)
			is_archive = is_archive || ends_with(file, suffix);
		if (is_archive) {
			extract_archive(path.string(), dest);
		} else {
			std::error_code ec;
			fs::copy(path, fs::path(dest) / file, fs::copy_options::recursive | fs::copy_options::overwrite_existing, ec);
			if (ec)
				throw std::runtime_error("could not copy " + path.string() + ": " + ec.message());
		}
	}
}

//
// The package
//

// .META as the former script wrote it
void write_meta(const recipe& r, const identity& id, const string& file)
{
	std::ofstream out(file, std::ios::trunc);
	out << "name: " << r.name << "\n"
	    << "version: " << id.version << "\n"
	    << "arch: " << id.arch << "\n";
	if (!r.description.empty())
		out << "description: " << r.description << "\n";
	if (!r.depends.empty()) {
		out << "depends: ";
		for (size_t i = 0; i < r.depends.size(); i++)
			out << (i ? ", " : "") << r.depends[i];
		out << "\n";
	}
	out.flush();
	if (!out)
		throw std::runtime_error("cannot write " + file);
}

struct build_options {
	string recipe = "Tatamifile";
	string masterdir = DEFAULT_MASTERDIR;
	string outdir;
	string compression;
	bool sign = true;
};

#ifndef TATAMI_SYSCONFDIR
#define TATAMI_SYSCONFDIR "etc"         // below the root, as in the Makefile
#endif

// The tatami binary that signs and indexes: $TATAMI, or tatami from PATH
string tatami_binary()
{
	const char* env = getenv("TATAMI");
	return env && *env ? env : "tatami";
}

bool program_exists(const string& program)
{
	if (program.find('/') != string::npos)
		return access(program.c_str(), X_OK) == 0;
	const char* path = getenv("PATH");
	std::istringstream dirs(path ? path : "");
	string dir;
	while (std::getline(dirs, dir, ':'))
		if (!dir.empty() && access((dir + "/" + program).c_str(), X_OK) == 0)
			return true;
	return false;
}

// The signing key as the former script found it: $TATAMI_PRIVKEY (which must then exist),
// otherwise ~/.tatami/privkey if there is one; empty means: do not sign
string signing_key(const build_options& o)
{
	if (!o.sign)
		return "";
	const char* env = getenv("TATAMI_PRIVKEY");
	if (env && *env) {
		if (access(env, R_OK) != 0)
			throw std::runtime_error(string("signing key ") + env + " (TATAMI_PRIVKEY) not found");
		return env;
	}
	const char* home = getenv("HOME");
	if (home && *home) {
		const string key = string(home) + "/.tatami/privkey";
		if (access(key.c_str(), R_OK) == 0)
			return key;
	}
	return "";
}

// A scratch root for 'tatami update', removed when it goes out of scope
class scratch_root {
public:
	scratch_root()
	{
		const char* tmp = getenv("TMPDIR");
		string pattern = string(tmp && *tmp ? tmp : "/tmp") + "/tatami-mkpkg-index.XXXXXX";
		if (!mkdtemp(&pattern[0]))
			throw std::runtime_error("could not create a temporary directory");
		path_ = pattern;
	}
	~scratch_root()
	{
		std::error_code ec;
		fs::remove_all(path_, ec);
	}
	scratch_root(const scratch_root&) = delete;
	scratch_root& operator=(const scratch_root&) = delete;
	const string& path() const { return path_; }
private:
	string path_;
};

// With a key: refresh the repository index of the output directory ('tatami update' indexes a
// local repository, so it gets the directory as the only one), then sign the package and the index
void sign_and_index(const string& outdir, const string& file, const string& key)
{
	const string tatami = tatami_binary();
	std::cerr << "=======> Signing with " << key << "\n";
	{
		scratch_root root;
		const string etc = root.path() + "/" + TATAMI_SYSCONFDIR + "/tatami";
		std::error_code ec;
		fs::create_directories(etc, ec);
		std::ofstream repos(etc + "/repos.conf");
		repos << "out = " << outdir << "\n";
		repos.flush();
		if (ec || !repos)
			throw std::runtime_error("could not write the repository list for " + outdir);
		repos.close();
		if (run_command({ tatami, "-r", root.path(), "update" }, true) != 0)
			throw std::runtime_error("could not update " + outdir + "/repo.solv");
	}
	if (run_command({ tatami, "sign", outdir + "/" + file, key }, true) != 0)
		throw std::runtime_error("could not sign " + file);
	if (run_command({ tatami, "sign", outdir + "/repo.solv", key }, true) != 0)
		throw std::runtime_error("could not sign repo.solv");
}

// Runs build() and package() in the sandbox, then packs $PKG; throws if anything fails
void run_build(const recipe& r, const build_options& o)
{
	std::error_code ec;
	const fs::path recipe_file = fs::canonical(o.recipe, ec);
	if (ec)
		throw std::runtime_error("recipe '" + o.recipe + "' not found");
	const fs::path recipe_dir = recipe_file.parent_path();
	const fs::path outdir = fs::absolute(o.outdir.empty() ? fs::current_path() : fs::path(o.outdir), ec);
	fs::create_directories(outdir, ec);
	if (ec)
		throw std::runtime_error("cannot create " + outdir.string() + ": " + ec.message());
	const string masterdir = fs::absolute(o.masterdir, ec).string();

	const naming nm = choose_naming(o.compression);
	const identity id = package_identity(r, nm);

	// the key is looked for first: a build that cannot be signed should not run
	const string key = signing_key(o);
	if (!key.empty() && !program_exists(tatami_binary()))
		throw std::runtime_error("tatami-mkpkg needs the tatami binary to sign and index ('" + tatami_binary() +
					 "' not found in PATH; set TATAMI=/path/to/tatami)");

	collect_sources(r, recipe_dir);
	prepare_masterdir(masterdir);

	workspace ws;                           // deleted when this function is left, however it is left
	unpack_sources(r, recipe_dir, ws.path() + "/src");

	std::cerr << "=======> Building " << id.file << " in " << ws.path() << "\n";
	vector<string> cmd = {
		"bwrap",
		"--unshare-all", "--die-with-parent", "--new-session",
		"--clearenv",
		"--ro-bind", masterdir, "/",
		"--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
		"--bind", ws.path(), "/build",
		"--chdir", "/build/src",
	};
	const std::map<string, string> env = {
		{ "PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" },
		{ "HOME", "/build" }, { "LANG", "C" },
		{ "SRC", "/build/src" }, { "PKG", "/build/pkg" }, { "DESTDIR", "/build/pkg" },
		{ "name", r.name }, { "version", r.version }, { "release", r.release },
	};
	for (const auto& kv : env)
		cmd.insert(cmd.end(), { "--setenv", kv.first, kv.second });
	cmd.insert(cmd.end(), { "--", "/bin/sh", "-c", build_script(r) });
	if (run_command(cmd) != 0)
		throw std::runtime_error("building " + r.name + " failed");

	const string pkgdir = ws.path() + "/pkg";
	if (fs::is_empty(pkgdir, ec))
		throw std::runtime_error("build() installed nothing into $PKG");

	std::cerr << "=======> Creating " << id.file << "\n";
	fs::remove(pkgdir + "/.META", ec);
	const fs::path install_script = recipe_dir / "tatami.install";      // bundled as .INSTALL
	if (fs::is_regular_file(install_script, ec)) {
		std::cerr << "=======> Bundling tatami.install as .INSTALL\n";
		fs::copy_file(install_script, pkgdir + "/.INSTALL", fs::copy_options::overwrite_existing, ec);
		if (ec)
			throw std::runtime_error("could not bundle tatami.install: " + ec.message());
		fs::permissions(pkgdir + "/.INSTALL", fs::perms::owner_read | fs::perms::owner_write | fs::perms::group_read |
				fs::perms::others_read, fs::perm_options::replace, ec);
	}
	const string meta = ws.path() + "/.META";
	write_meta(r, id, meta);

	const string target = (outdir / id.file).string(), part = target + ".part";
	try {
		pack_archive(nm.compression, meta, pkgdir, part);
		if (rename(part.c_str(), target.c_str()) != 0)
			throw std::runtime_error(string("cannot create ") + target + ": " + strerror(errno));
	} catch (...) {
		unlink(part.c_str());
		throw;
	}
	if (!key.empty())
		sign_and_index(outdir.string(), id.file, key);
	else
		std::cerr << "=======> Not signing (no key: run 'tatami keygen')\n";
	std::cerr << "=======> Built " << target << "\n";
}

void usage(std::ostream& out)
{
	out << "usage: tatami-mkpkg [options]\n"
	       "  -f, --file <recipe>        recipe to build (default: Tatamifile)\n"
	       "  -o, --output <dir>         where to put the package (default: current directory)\n"
	       "  -m, --masterdir <dir>      read-only root of the sandbox (default: " << DEFAULT_MASTERDIR << ")\n"
	       "  -z, --compression <c>      gz, xz, zst, bz2, lz4, lzma or none (default: '" DEFAULT_PKG_COMPRESSION "')\n"
	       "      --no-sign              do not sign the package even if a signing key exists\n"
	       "  -v, --version              print the version and exit\n"
	       "  -h, --help                 print this help\n"
	       "packages are named <name>_<version>[-<release>]_<arch>.<extension>; the extension is\n"
	       "tar.<compression> if PKG_EXT is empty (fixed when tatami was built: '" DEFAULT_PKG_EXT "')\n"
	       "signing: if $TATAMI_PRIVKEY or ~/.tatami/privkey exists (see 'tatami keygen'), the\n"
	       "package is signed (<package>.sig) and the output directory's repo.solv is updated\n"
	       "and signed (repo.solv.sig) as part of the build, with the tatami binary ($TATAMI)\n";
}

} // namespace

int main(int argc, char** argv)
{
	build_options o;
	try {
		for (int i = 1; i < argc; i++) {
			const string a = argv[i];
			auto value = [&]() -> string {
				if (i + 1 >= argc || !*argv[i + 1])
					throw std::runtime_error("option " + a + " requires an argument");
				return argv[++i];
			};
			if (a == "-f" || a == "--file")
				o.recipe = value();
			else if (a == "-o" || a == "--output")
				o.outdir = value();
			else if (a == "-m" || a == "--masterdir")
				o.masterdir = value();
			else if (a == "-z" || a == "--compression")
				o.compression = value();
			else if (a == "--no-sign")
				o.sign = false;
			else if (a == "-v" || a == "--version") {
				std::cout << "tatami-mkpkg " VERSION "\n";
				return 0;
			} else if (a == "-h" || a == "--help") {
				usage(std::cout);
				return 0;
			} else
				throw std::runtime_error("invalid option " + a);
		}

		install_signal_handlers();
		if (access(o.recipe.c_str(), R_OK) != 0)
			throw std::runtime_error("recipe '" + o.recipe + "' not found");
		const recipe r = read_recipe(o.recipe);
		run_build(r, o);
	} catch (const raw_error& e) {
		std::cerr << e.what() << "\n";
		return 1;
	} catch (const std::exception& e) {
		std::cerr << "=======> ERROR: " << e.what() << "\n";
		return 1;
	}
	return 0;
}
