#ifndef COMMANDS_H
#define COMMANDS_H

#include "config.h"
#include <string>
#include <vector>

using namespace std;

struct options {
	string root;            // installation root (absolute, as given by -r)
	string config;          // explicit configuration file, "" for the default
	bool yes;               // assume yes to all questions
	bool force;             // overwrite conflicting files
	bool simulate;          // only show what would be done
	bool installed_only;    // list: only installed packages
	bool upgradable_only;   // list: only upgradable packages
	bool available_only;    // list: only packages in the index

	options() : root("/"), yes(false), force(false), simulate(false),
		    installed_only(false), upgradable_only(false), available_only(false) {}
};

struct context {
	options opt;
	config_t cfg;
	string arch;            // architecture used for solving
	vector<string> args;    // arguments of the command
};

typedef void (*command_fn)(context&);

struct command_t {
	const char* name;
	const char* alias;
	const char* usage;
	const char* help;
	bool needs_root;        // modifies the system (unless --simulate)
	command_fn run;
};

const command_t* find_command(const string& name);
const command_t* all_commands(size_t& count);

#endif /* COMMANDS_H */
