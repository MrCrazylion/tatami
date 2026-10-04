//
//  tatami - a package manager in the spirit of pkgutils, with apt-style
//  commands and libsolv dependency resolution.
//

#include "bulkhead.h"
#include "pack.h"
#include "commands.h"
#include "config.h"
#include "rootfs.h"
#include "util.h"
#include <iostream>
#include <cstdlib>
#include <sys/utsname.h>
#include <unistd.h>

#ifndef VERSION
#define VERSION "unknown"
#endif

static void print_help()
{
	size_t count;
	const command_t* commands = all_commands(count);

	cout << "usage: tatami [options] <command> [arguments]" << endl
	     << endl
	     << "commands:" << endl;
	for (size_t i = 0; i < count; i++) {
		cout << "  ";
		cout.width(24);
		cout << left << commands[i].usage << commands[i].help << endl;
	}
	cout << "  ";
	cout.width(24);
	cout << left << "bulkhead <dir> -- <cmd>" << "run a command in a bwrap sandbox (used by tatamk)" << endl;
	cout << "  ";
	cout.width(24);
	cout << left << "pack <meta> <dir> <out>" << "create a package archive (used by tatamk), -z <compression>" << endl;
	cout << endl
	     << "options:" << endl
	     << "  -y, --yes            do not ask for confirmation" << endl
	     << "  -f, --force          overwrite conflicting files" << endl
	     << "  -s, --simulate       show what would be done, change nothing" << endl
	     << "  -r, --root <path>    use an alternative installation root" << endl
	     << "  -c, --config <file>  use an alternative configuration file" << endl
	     << "      --installed      list: installed packages (the default)" << endl
	     << "      --upgradable     list: installed packages with a newer version available" << endl
	     << "      --available      list: packages in the repository index instead" << endl
	     << "  -v, --version        print version and exit" << endl
	     << "  -h, --help           print help and exit" << endl;
}

static string need_value(int argc, char** argv, int i)
{
	if (i + 1 >= argc)
		throw runtime_error("option " + string(argv[i]) + " requires an argument");
	return argv[i + 1];
}

int main(int argc, char** argv)
{
	// Not a package command: no configuration, no root, and the exit status
	// of the sandboxed command is passed through unchanged.
	if (argc >= 2 && string(argv[1]) == "bulkhead")
		return bulkhead_main(argc, argv);
	if (argc >= 2 && string(argv[1]) == "pack")
		return pack_main(argc, argv);

	try {
		context ctx;
		string command;

		for (int i = 1; i < argc; i++) {
			const string option = argv[i];

			if (option == "-h" || option == "--help") {
				print_help();
				return EXIT_SUCCESS;
			} else if (option == "-v" || option == "--version") {
				cout << "tatami " << VERSION << endl;
				return EXIT_SUCCESS;
			} else if (option == "-y" || option == "--yes") {
				ctx.opt.yes = true;
			} else if (option == "-f" || option == "--force") {
				ctx.opt.force = true;
			} else if (option == "-s" || option == "--simulate" || option == "--dry-run") {
				ctx.opt.simulate = true;
			} else if (option == "-r" || option == "--root") {
				ctx.opt.root = need_value(argc, argv, i++);
				if (ctx.opt.root.empty())
					throw runtime_error("option " + option + " requires a non-empty path");
			} else if (option == "-c" || option == "--config") {
				ctx.opt.config = need_value(argc, argv, i++);
			} else if (option == "--installed") {
				ctx.opt.installed_only = true;
			} else if (option == "--upgradable") {
				ctx.opt.upgradable_only = true;
			} else if (option == "--available") {
				ctx.opt.available_only = true;
			} else if (option == "--") {
				for (i++; i < argc; i++) {
					if (command.empty())
						command = argv[i];
					else
						ctx.args.push_back(argv[i]);
				}
			} else if (option.size() > 1 && option[0] == '-') {
				throw runtime_error("invalid option " + option);
			} else if (command.empty()) {
				command = option;
			} else {
				ctx.args.push_back(option);
			}
		}

		if (command.empty()) {
			print_help();
			return EXIT_FAILURE;
		}

		const command_t* cmd = find_command(command);
		if (!cmd)
			throw runtime_error("unknown command '" + command + "' (see 'tatami --help')");

		if (cmd->needs_root && !ctx.opt.simulate && getuid())
			throw runtime_error("only root can run '" + string(cmd->name) + "'");

		ctx.opt.root = real_path(ctx.opt.root);

		const bool explicit_config = !ctx.opt.config.empty();
		ctx.cfg = read_config(explicit_config ? ctx.opt.config
						      : root_resolve(ctx.opt.root, TATAMI_CONF),
				      explicit_config);

		ctx.arch = ctx.cfg.arch;
		if (ctx.arch.empty()) {
			struct utsname un;
			if (uname(&un) == -1)
				throw runtime_error_with_errno("could not determine the machine architecture");
			ctx.arch = un.machine;
		}

		cmd->run(ctx);
	} catch (runtime_error& e) {
		cerr << "tatami: " << e.what() << endl;
		return EXIT_FAILURE;
	}

	return EXIT_SUCCESS;
}
