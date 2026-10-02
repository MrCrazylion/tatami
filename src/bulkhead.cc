#include "bulkhead.h"
#include "util.h"
#include <iostream>
#include <cstring>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void say(const string& message)
{
	const string line = "tatami: " + message + "\n";
	ssize_t n = write(STDERR_FILENO, line.data(), line.size());
	(void)n;
}

vector<string> bulkhead_args(const string& destdir, const vector<string>& command)
{
	const char* fixed[] = {
		"bwrap",
		"--ro-bind", "/", "/",
		"--dev", "/dev",
		"--tmpfs", "/tmp",
		"--bind", 0, "/tmp/destdir",
		"--unshare-net",
		"--unshare-pid",
		"--die-with-parent",
		"--",
	};
	vector<string> args;

	for (size_t i = 0; i < sizeof(fixed) / sizeof(fixed[0]); i++)
		args.push_back(fixed[i] ? fixed[i] : destdir);
	args.insert(args.end(), command.begin(), command.end());

	return args;
}

int bulkhead_run(const vector<string>& args)
{
	vector<char*> argv;
	for (size_t i = 0; i < args.size(); i++)
		argv.push_back(const_cast<char*>(args[i].c_str()));
	argv.push_back(0);

	pid_t pid = fork();
	if (pid == -1) {
		say(string("could not run ") + args[0] + ": fork failed: " + strerror(errno));
		return BULKHEAD_EXIT_LAUNCH;
	}

	if (pid == 0) {
		execvp(argv[0], &argv[0]);
		// Only reached if bwrap could not be started
		say(string("could not run ") + args[0] + ": " + strerror(errno));
		_exit(BULKHEAD_EXIT_LAUNCH);
	}

	int status;
	pid_t r;
	while ((r = waitpid(pid, &status, 0)) == -1 && errno == EINTR)
		;
	if (r == -1) {
		say(string("could not run ") + args[0] + ": waitpid failed: " + strerror(errno));
		return BULKHEAD_EXIT_LAUNCH;
	}

	if (WIFEXITED(status))
		return WEXITSTATUS(status);

	if (WIFSIGNALED(status)) {
		const int sig = WTERMSIG(status);
		const char* name = strsignal(sig);
		say(string("build terminated by signal ") + itos(sig) + " (" + (name ? name : "unknown") + ")");
		return 128 + sig;
	}

	say("build ended in an unexpected state");
	return BULKHEAD_EXIT_LAUNCH;
}

static int usage(int code)
{
	(code ? cerr : cout) << "usage: tatami bulkhead <host_destdir> -- <command> [args...]" << endl
	    << "  Runs <command> in a bubblewrap sandbox: read-only host root, tmpfs /tmp," << endl
	    << "  no network, <host_destdir> mapped to /tmp/destdir." << endl;
	return code;
}

int bulkhead_main(int argc, char** argv)
{
	// argv: tatami bulkhead <host_destdir> -- <command> [args...]
	if (argc == 3 && (!strcmp(argv[2], "-h") || !strcmp(argv[2], "--help")))
		return usage(0);

	if (argc < 5 || strcmp(argv[3], "--"))
		return usage(BULKHEAD_EXIT_USAGE);

	string destdir;
	try {
		destdir = real_path(argv[2]);
	} catch (runtime_error& e) {
		say(string("bulkhead: ") + e.what());
		return BULKHEAD_EXIT_USAGE;
	}

	struct stat st;
	if (stat(destdir.c_str(), &st) == -1 || !S_ISDIR(st.st_mode)) {
		say("bulkhead: " + destdir + " is not a directory");
		return BULKHEAD_EXIT_USAGE;
	}

	vector<string> command(argv + 4, argv + argc);
	return bulkhead_run(bulkhead_args(destdir, command));
}
