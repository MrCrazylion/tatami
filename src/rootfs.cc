#include "rootfs.h"
#include "util.h"
#include <deque>
#include <vector>
#include <climits>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_LINKS 40

static void components(const string& path, deque<string>& out, bool front)
{
	vector<string> parts;
	string::size_type pos = 0;

	while (pos <= path.size()) {
		string::size_type end = path.find('/', pos);
		if (end == string::npos)
			end = path.size();
		if (end > pos)
			parts.push_back(path.substr(pos, end - pos));
		pos = end + 1;
	}

	if (front)
		out.insert(out.begin(), parts.begin(), parts.end());
	else
		out.insert(out.end(), parts.begin(), parts.end());
}

string root_resolve(const string& root_in, const string& rel)
{
	string root = root_in;
	while (!root.empty() && root[root.size() - 1] == '/')
		root.erase(root.size() - 1);

	deque<string> pending;
	vector<string> stack;
	int links = 0;
	bool exists = true;

	components(rel, pending, false);

	while (!pending.empty()) {
		const string c = pending.front();
		pending.pop_front();

		if (c == ".")
			continue;
		if (c == "..") {
			if (!stack.empty())
				stack.pop_back();
			continue;
		}

		stack.push_back(c);

		// The last component is not followed, nor is anything below a
		// component that does not exist
		if (pending.empty() || !exists)
			continue;

		string cur = root;
		for (size_t i = 0; i < stack.size(); i++)
			cur += "/" + stack[i];

		struct stat st;
		if (lstat(cur.c_str(), &st) == -1) {
			exists = false;
			continue;
		}
		if (!S_ISLNK(st.st_mode))
			continue;

		if (++links > MAX_LINKS)
			throw runtime_error("too many levels of symbolic links in " + rel);

		char buf[PATH_MAX];
		ssize_t n = readlink(cur.c_str(), buf, sizeof(buf) - 1);
		if (n == -1)
			throw runtime_error_with_errno("could not read the link " + cur);
		buf[n] = '\0';

		const string target = buf;
		stack.pop_back();
		if (!target.empty() && target[0] == '/')
			stack.clear();          // absolute: relative to the root, not to the host
		components(target, pending, true);
	}

	string result = root;
	for (size_t i = 0; i < stack.size(); i++)
		result += "/" + stack[i];

	return result.empty() ? "/" : result;
}
