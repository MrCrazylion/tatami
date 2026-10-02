#ifndef ENGINE_H
#define ENGINE_H

#include "config.h"
#include "db.h"
#include <regex.h>
#include <memory>
#include <set>
#include <string>
#include <vector>

using namespace std;

// Applies single package operations to the installed system. This is the
// pkgadd/pkgrm logic of pkgutils: INSTALL/UPGRADE rules, conflict handling,
// rejected files and the database commit protocol.
class engine {
public:
	engine(const config_t& cfg, database& db, bool force);

	// Installs or upgrades (if the package is already installed) a package file
	void install(const string& filename);
	void remove(const string& name);
	void ldconfig() const;

private:
	struct compiled_rule {
		rule_event_t event;
		bool action;
		shared_ptr<regex_t> re;
	};

	set<string> make_keep_list(const set<string>& files) const;
	set<string> apply_install_rules(set<string>& files) const;
	bool rule_applies(const compiled_rule& rule, const string& file) const;

	database& db_;
	bool force_;
	vector<compiled_rule> rules_;
};

#endif /* ENGINE_H */
