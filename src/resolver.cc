#include <algorithm>
#include "resolver.h"
#include "util.h"
#include <cstring>
#include <unistd.h>
#include <cctype>
#include <iostream>
#include <cstdio>
#include <cstdlib>
#include <set>

extern "C" {
#include <solv/poolarch.h>
#include <solv/selection.h>
#include <solv/solvable.h>
#include <solv/solverdebug.h>
#include <solv/evr.h>
#include <solv/knownid.h>
#include <solv/repo_solv.h>
#include <solv/repo_write.h>
}

// The architecture a package is solved with. Architecture-independent
// packages (noarch, all, any; any capitalisation) are installable on every
// host, so they are always filed under libsolv's "noarch". A package without
// an architecture is treated as noarch too, except an installed one (stored
// metadata may predate the field), which is assumed to be for this host.
static string effective_arch(const string& arch, const string& host, bool installed)
{
	string a = trim(arch);
	for (string::size_type i = 0; i < a.size(); i++)
		a[i] = tolower((unsigned char)a[i]);

	if (a.empty())
		return installed ? host : "noarch";
	if (a == "noarch" || a == "all" || a == "any")
		return "noarch";
	return arch;
}

resolver::resolver(const string& arch)
	: installed_(0), local_(0), solv_(0), trans_(0), arch_(arch), ready_(false), erasing_(false)
{
	pool_ = pool_create();
	// Strict: the listed architectures and noarch, nothing else
	pool_setarchpolicy(pool_, arch_.c_str());
	// "replaces" is matched against everything a package provides (virtual
	// provides included), not only against package names.
	pool_set_flag(pool_, POOL_FLAG_OBSOLETEUSESPROVIDES, 1);
	queue_init(&job_);

	installed_ = repo_create(pool_, "@installed");
	local_ = repo_create(pool_, "commandline");
	pool_set_installed(pool_, installed_);
}

resolver::~resolver()
{
	clear_solution();
	queue_free(&job_);
	pool_free(pool_);
}

void resolver::clear_solution()
{
	if (trans_) {
		transaction_free(trans_);
		trans_ = 0;
	}
	if (solv_) {
		solver_free(solv_);
		solv_ = 0;
	}
}

Id resolver::parse_one_dep(const string& text)
{
	string s = trim(text);
	string::size_type pos = s.find_first_of("<>=");

	if (pos == string::npos) {
		if (s.empty() || s.find_first_of(" \t()") != string::npos)
			throw runtime_error("invalid dependency '" + text + "'");
		return pool_str2id(pool_, s.c_str(), 1);
	}

	// "name op version" or "name (op version)"
	string name = s.substr(0, pos);
	string::size_type paren = name.find('(');
	if (paren != string::npos)
		name.erase(paren);
	name = trim(name);

	string op;
	string::size_type q = pos;
	while (q < s.size() && strchr("<>=", s[q]))
		op += s[q++];

	string version = s.substr(q);
	string::size_type close = version.find(')');
	if (close != string::npos)
		version.erase(close);
	version = trim(version);

	if (name.empty() || version.empty() || name.find_first_of(" \t()") != string::npos ||
	    version.find_first_of(" \t()") != string::npos)
		throw runtime_error("invalid dependency '" + text + "'");

	int flags;
	if (op == "<" || op == "<<")
		flags = REL_LT;
	else if (op == "<=")
		flags = REL_LT | REL_EQ;
	else if (op == "=" || op == "==")
		flags = REL_EQ;
	else if (op == ">=")
		flags = REL_GT | REL_EQ;
	else if (op == ">" || op == ">>")
		flags = REL_GT;
	else
		throw runtime_error("invalid dependency '" + text + "': unknown operator '" + op + "'");

	return pool_rel2id(pool_, pool_str2id(pool_, name.c_str(), 1),
			   pool_str2id(pool_, version.c_str(), 1), flags, 1);
}

// "a | b" alternatives become REL_OR relations
Id resolver::parse_dep(const string& text)
{
	vector<string> alts = split(text, "|");
	if (alts.empty())
		throw runtime_error("empty dependency");

	Id result = parse_one_dep(alts[0]);
	for (vector<string>::size_type i = 1; i < alts.size(); i++)
		result = pool_rel2id(pool_, result, parse_one_dep(alts[i]), REL_OR, 1);

	return result;
}

Id resolver::add_solvable(Repo* repo, const pkgmeta& meta)
{
	// Parse every relation first so that a malformed one leaves no
	// half-built solvable behind.
	vector<Id> requires_, conflicts_, provides_, obsoletes_;
	try {
		vector<string> list = split(meta.depends, ",");
		for (size_t i = 0; i < list.size(); i++)
			requires_.push_back(parse_dep(list[i]));

		list = split(meta.conflicts, ",");
		for (size_t i = 0; i < list.size(); i++)
			conflicts_.push_back(parse_dep(list[i]));

		list = split(meta.provides, ",");
		for (size_t i = 0; i < list.size(); i++)
			provides_.push_back(parse_one_dep(list[i]));

		list = split(meta.replaces, ",");
		for (size_t i = 0; i < list.size(); i++)
			obsoletes_.push_back(parse_dep(list[i]));
	} catch (runtime_error& e) {
		throw runtime_error("package " + meta.name + ": " + e.what());
	}

	Id p = repo_add_solvable(repo);
	Solvable* s = pool_id2solvable(pool_, p);

	const string arch = effective_arch(meta.arch, arch_.substr(0, arch_.find_first_of(":=>")), repo == installed_);

	s->name = pool_str2id(pool_, meta.name.c_str(), 1);
	s->evr = pool_str2id(pool_, meta.version.c_str(), 1);
	s->arch = pool_str2id(pool_, arch.c_str(), 1);

	// A package always provides itself
	s->provides = repo_addid_dep(repo, s->provides,
				     pool_rel2id(pool_, s->name, s->evr, REL_EQ, 1), 0);

	for (size_t i = 0; i < requires_.size(); i++)
		s->requires = repo_addid_dep(repo, s->requires, requires_[i], 0);
	for (size_t i = 0; i < conflicts_.size(); i++)
		s->conflicts = repo_addid_dep(repo, s->conflicts, conflicts_[i], 0);
	for (size_t i = 0; i < provides_.size(); i++)
		s->provides = repo_addid_dep(repo, s->provides, provides_[i], 0);
	for (size_t i = 0; i < obsoletes_.size(); i++)
		s->obsoletes = repo_addid_dep(repo, s->obsoletes, obsoletes_[i], 0);

	if (!meta.description.empty())
		repo_set_str(repo, p, SOLVABLE_SUMMARY, meta.description.c_str());
	if (!meta.filename.empty())
		repo_set_str(repo, p, SOLVABLE_MEDIAFILE, meta.filename.c_str());
	if (meta.size)
		repo_set_num(repo, p, SOLVABLE_DOWNLOADSIZE, meta.size);
	if (!meta.checksum.empty()) {
		Repodata* data = repo_last_repodata(repo);
		if (!data)
			data = repo_add_repodata(repo, 0);
		repodata_set_checksum(data, p, SOLVABLE_CHECKSUM, REPOKEY_TYPE_SHA256, meta.checksum.c_str());
	}

	ready_ = false;
	return p;
}

void resolver::add_installed(const packages_t& packages, const database& db)
{
	for (packages_t::const_iterator i = packages.begin(); i != packages.end(); ++i) {
		pkgmeta meta;
		const pkgmeta* stored = db.meta(i->first);

		if (stored)
			meta = *stored;
		meta.name = i->first;
		meta.version = i->second.version;

		Id p;
		try {
			p = add_solvable(installed_, meta);
		} catch (runtime_error& e) {
			// Unusable stored metadata: keep the package, without its relations
			cerr << "tatami: warning: " << e.what() << " (ignoring its dependency information)" << endl;
			pkgmeta bare;
			bare.name = meta.name;
			bare.version = meta.version;
			bare.arch = meta.arch;
			p = add_solvable(installed_, bare);
		}

		if (db.reason(i->first) == REASON_DEPENDENCY)
			dependency_[i->first] = true;
		else
			explicit_ids_.push_back(p);
	}
	repo_internalize(installed_);
}

Repo* resolver::new_repo(const string& dir)
{
	Repo* repo = repo_create(pool_, dir.c_str());
	// The first repository listed is the preferred one
	repo->priority = 1000 - (int)repos_.size();
	repos_.push_back(repo);
	repo_dir_[repo] = dir;
	ready_ = false;
	return repo;
}

void resolver::add_repo(const string& dir, const vector<pkgmeta>& entries)
{
	Repo* repo = new_repo(dir);

	for (vector<pkgmeta>::const_iterator i = entries.begin(); i != entries.end(); ++i) {
		try {
			// file names are kept relative to the repository, like in repo.solv
			pkgmeta m = *i;
			m.filename = m.filename.substr(m.filename.rfind('/') + 1);
			add_solvable(repo, m);
		} catch (runtime_error& e) {
			cerr << "tatami: warning: ignoring " << e.what() << endl;
		}
	}
	repo_internalize(repo);
}

void resolver::add_repo_solv(const string& dir, const string& solv_file)
{
	FILE* fp = fopen(solv_file.c_str(), "r");
	if (!fp)
		throw runtime_error_with_errno("could not open " + solv_file);

	Repo* repo = new_repo(dir);
	const int r = repo_add_solv(repo, fp, 0);
	fclose(fp);
	if (r != 0)
		throw runtime_error(solv_file + " is not a valid index (" + pool_errstr(pool_) + "); run 'tatami index " + dir + "'");
}

void resolver::write_solv(const string& dir, const vector<pkgmeta>& entries, const string& solv_file)
{
	resolver r("noarch");           // the file holds every architecture: nothing is filtered here
	r.add_repo(dir, entries);

	FILE* fp = fopen(solv_file.c_str(), "w");
	if (!fp)
		throw runtime_error_with_errno("could not create " + solv_file);
	if (repo_write(r.repos_[0], fp) != 0 || fflush(fp) == EOF || fsync(fileno(fp)) == -1) {
		const int e = errno;
		fclose(fp);
		throw runtime_error_with_errno("could not write " + solv_file, e);
	}
	if (fclose(fp) == EOF)
		throw runtime_error_with_errno("could not write " + solv_file);
}

// The file of a solvable: relative to its repository, absolute for a package
// file given on the command line
string resolver::solvable_file(Id p) const
{
	Solvable* s = pool_id2solvable(pool_, p);
	const char* f = solvable_lookup_str(s, SOLVABLE_MEDIAFILE);
	if (!f)
		return "";
	if (f[0] == '/')
		return f;

	map<Repo*, string>::const_iterator d = repo_dir_.find(s->repo);
	return d == repo_dir_.end() ? string(f) : d->second + "/" + f;
}

vector<pkgmeta> resolver::available_meta() const
{
	vector<pkgmeta> result;

	for (size_t r = 0; r < repos_.size(); r++) {
		Id p;
		Solvable* s;
		FOR_REPO_SOLVABLES(repos_[r], p, s) {
			pkgmeta m;
			m.name = pool_id2str(pool_, s->name);
			m.version = pool_id2str(pool_, s->evr);
			m.arch = pool_id2str(pool_, s->arch);
			const char* summary = solvable_lookup_str(s, SOLVABLE_SUMMARY);
			if (summary)
				m.description = summary;
			m.filename = solvable_file(p);
			m.size = solvable_lookup_num(s, SOLVABLE_DOWNLOADSIZE, 0);
			Id chktype = 0;
			const char* chk = solvable_lookup_checksum(s, SOLVABLE_CHECKSUM, &chktype);
			if (chk && chktype == REPOKEY_TYPE_SHA256)
				m.checksum = chk;

			// the relations, as the text they were written as ("a >= 1", "a | b");
			// the implicit "provides itself" is not shown
			const string self = m.name + " = " + m.version;
			struct { Offset off; string* out; bool provides; } lists[] = {
				{ s->requires, &m.depends, false },
				{ s->conflicts, &m.conflicts, false },
				{ s->provides, &m.provides, true },
				{ s->obsoletes, &m.replaces, false },
			};
			for (size_t l = 0; l < sizeof(lists) / sizeof(lists[0]); l++) {
				if (!lists[l].off)
					continue;
				Id id, *ids = repos_[r]->idarraydata + lists[l].off;
				while ((id = *ids++) != 0) {
					if (id == SOLVABLE_PREREQMARKER || id == SOLVABLE_FILEMARKER)
						continue;
					const string text = pool_dep2str(pool_, id);
					if (lists[l].provides && text == self)
						continue;
					*lists[l].out += (lists[l].out->empty() ? "" : ", ") + text;
				}
			}
			result.push_back(m);
		}
	}

	return result;
}

Id resolver::add_local(const pkgmeta& meta)
{
	Id p = add_solvable(local_, meta);
	repo_internalize(local_);
	return p;
}

void resolver::prepare()
{
	if (!ready_) {
		pool_createwhatprovides(pool_);
		ready_ = true;
	}
}

void resolver::want_install(const string& spec)
{
	prepare();

	// Accept "name=version" as a shorthand for "name = version"
	string text = spec;
	int flags = SELECTION_NAME | SELECTION_PROVIDES;
	string::size_type eq = text.find('=');
	if (eq != string::npos) {
		text = trim(text.substr(0, eq)) + " = " + trim(text.substr(eq + 1));
		flags |= SELECTION_REL;
	}

	Queue sel;
	queue_init(&sel);
	selection_make(pool_, &sel, text.c_str(), flags);
	if (sel.count == 0) {
		queue_free(&sel);

		// Not found for this architecture: is it there for another one?
		const string wanted = trim(spec.substr(0, spec.find('=')));
		Id nameid = pool_str2id(pool_, wanted.c_str(), 0);
		string archs;
		for (size_t r = 0; nameid && r < repos_.size(); r++) {
			Id p;
			Solvable* s;
			FOR_REPO_SOLVABLES(repos_[r], p, s) {
				if (s->name != nameid)
					continue;
				const string a = pool_id2str(pool_, s->arch);
				if (archs.find(a) == string::npos)
					archs += (archs.empty() ? "" : ", ") + a;
			}
		}
		if (!archs.empty())
			throw runtime_error("package " + wanted + " is built for architecture " + archs +
					    ", which is incompatible with this system (" + arch_ + ")");
		throw runtime_error("unable to locate package " + spec);
	}

	// Only consider selections that contain something that can be installed
	Queue solvables;
	queue_init(&solvables);
	selection_solvables(pool_, &sel, &solvables);
	bool installable = false;
	set<string> candidates;
	for (int i = 0; i < solvables.count; i++) {
		Solvable* cand = pool_id2solvable(pool_, solvables.elements[i]);
		if (pool_installable(pool_, cand)) {
			installable = true;
			candidates.insert(pool_id2str(pool_, cand->name));
		}
	}
	queue_free(&solvables);

	if (!installable) {
		queue_free(&sel);
		throw runtime_error("package " + spec + " has no installation candidate (architecture " + arch_ + ")");
	}

	requested_.insert(candidates.begin(), candidates.end());

	// Installing an installed package upgrades it, unless a version is pinned
	for (int i = 0; i < sel.count; i += 2) {
		queue_push2(&job_, sel.elements[i] | SOLVER_INSTALL, sel.elements[i + 1]);
		if (eq == string::npos)
			queue_push2(&job_, sel.elements[i] | SOLVER_UPDATE, sel.elements[i + 1]);
	}
	queue_free(&sel);
}

void resolver::want_install_solvable(Id p)
{
	if (!pool_installable(pool_, pool_id2solvable(pool_, p)))
		throw runtime_error("package " + string(pool_id2str(pool_, pool_id2solvable(pool_, p)->name)) +
				    " has an architecture that cannot be installed on " + arch_);
	requested_.insert(pool_id2str(pool_, pool_id2solvable(pool_, p)->name));
	queue_push2(&job_, SOLVER_SOLVABLE | SOLVER_INSTALL, p);
}

void resolver::want_erase(const string& name)
{
	prepare();

	Id nameid = pool_str2id(pool_, name.c_str(), 0);
	bool found = false;

	if (nameid) {
		Id p;
		Solvable* s;
		FOR_REPO_SOLVABLES(installed_, p, s)
			if (s->name == nameid)
				found = true;
	}
	if (!found)
		throw runtime_error("package " + name + " not installed");

	queue_push2(&job_, SOLVER_SOLVABLE_NAME | SOLVER_ERASE | SOLVER_CLEANDEPS, nameid);
	erase_targets_.insert(name);
	erasing_ = true;
}

void resolver::want_upgrade_all()
{
	prepare();
	queue_push2(&job_, SOLVER_SOLVABLE_ALL | SOLVER_UPDATE, 0);
}

// The job queue handed to the solver. When removing, every installed package
// the user asked for is declared SOLVER_USERINSTALLED: it is the input libsolv
// needs to tell which dependencies became unneeded (SOLVER_CLEANDEPS).
Id resolver::installed_id(const string& name) const
{
	Id nameid = pool_str2id(pool_, name.c_str(), 0);
	if (!nameid)
		return 0;
	Id p;
	Solvable* s;
	FOR_REPO_SOLVABLES(installed_, p, s)
		if (s->name == nameid)
			return p;
	return 0;
}

// A held package the command does not name itself
bool resolver::is_held(const string& name) const
{
	return find(held_.begin(), held_.end(), name) != held_.end() &&
	       requested_.count(name) == 0 && erase_targets_.count(name) == 0;
}

vector<string> resolver::held_back() const
{
	vector<string> result;
	for (size_t i = 0; i < held_.size(); i++) {
		const Id p = installed_id(held_[i]);
		if (!p || !is_held(held_[i]))
			continue;
		const string have = pool_id2str(pool_, pool_id2solvable(pool_, p)->evr);
		const string best = best_available(held_[i]);
		if (!best.empty() && newer(best, have))
			result.push_back(held_[i] + " (" + have + " -> " + best + ")");
	}
	return result;
}

void resolver::make_jobs(Queue* jobs) const
{
	queue_init_clone(jobs, &job_);
	// hold file: libsolv must leave these installed packages exactly as they are
	for (size_t i = 0; i < held_.size(); i++) {
		const Id p = installed_id(held_[i]);
		if (p && is_held(held_[i]))
			queue_push2(jobs, SOLVER_SOLVABLE | SOLVER_LOCK, p);
	}
	if (erasing_)
		for (size_t i = 0; i < explicit_ids_.size(); i++)
			queue_push2(jobs, SOLVER_SOLVABLE | SOLVER_USERINSTALLED, explicit_ids_[i]);
}

void resolver::collect_problems(Solver* solv, vector<string>& out) const
{
	if (solver_problem_count(solv) == 0)
		return;

	Id problem = 0;
	while ((problem = solver_next_problem(solv, problem)) != 0) {
		Id rule = solver_findproblemrule(solv, problem);
		Id source, target, dep;
		SolverRuleinfo type = solver_ruleinfo(solv, rule, &source, &target, &dep);
		out.push_back(solver_problemruleinfo2str(solv, type, source, target, dep));
	}
}

// If the job fails only because installed packages would have to go back to
// an older version, say so (libsolv alone just reports unsatisfiable requires).
string resolver::downgrade_hint()
{
	Solver* alt = solver_create(pool_);
	solver_set_flag(alt, SOLVER_FLAG_ALLOW_ARCHCHANGE, 1);
	solver_set_flag(alt, SOLVER_FLAG_ALLOW_VENDORCHANGE, 1);
	solver_set_flag(alt, SOLVER_FLAG_ALLOW_DOWNGRADE, 1);
	if (erasing_)
		solver_set_flag(alt, SOLVER_FLAG_ALLOW_UNINSTALL, 1);

	string hint;
	Queue jobs;
	make_jobs(&jobs);
	if (solver_solve(alt, &jobs) == 0) {
		Transaction* t = solver_create_transaction(alt);
		const int active = SOLVER_TRANSACTION_SHOW_ACTIVE | SOLVER_TRANSACTION_SHOW_OBSOLETES;
		for (int i = 0; i < t->steps.count; i++) {
			Id p = t->steps.elements[i];
			if (transaction_type(t, p, active) != SOLVER_TRANSACTION_DOWNGRADE)
				continue;
			Solvable* s = pool_id2solvable(pool_, p);
			Id old = transaction_obs_pkg(t, p);
			hint += (hint.empty() ? "" : ", ");
			hint += string(pool_id2str(pool_, s->name)) + " (" +
				(old ? pool_id2str(pool_, pool_id2solvable(pool_, old)->evr) : "?") +
				" -> " + pool_id2str(pool_, s->evr) + ")";
		}
		transaction_free(t);
	}
	queue_free(&jobs);
	solver_free(alt);

	if (hint.empty())
		return hint;
	return "this would only work by downgrading: " + hint +
	       "; tatami does not downgrade on its own, install the older version explicitly (name=version) if you want that";
}

bool resolver::solve()
{
	prepare();
	clear_solution();
	problems_.clear();

	solv_ = solver_create(pool_);
	solver_set_flag(solv_, SOLVER_FLAG_ALLOW_ARCHCHANGE, 1);
	solver_set_flag(solv_, SOLVER_FLAG_ALLOW_VENDORCHANGE, 1);
	// Removing a package also removes what depends on it
	if (erasing_)
		solver_set_flag(solv_, SOLVER_FLAG_ALLOW_UNINSTALL, 1);

	Queue jobs;
	make_jobs(&jobs);
	const int unsolved = solver_solve(solv_, &jobs);
	queue_free(&jobs);

	if (unsolved != 0) {
		collect_problems(solv_, problems_);
		if (problems_.empty())
			problems_.push_back("the dependency solver found no solution");
		string hint = downgrade_hint();
		if (!hint.empty())
			problems_.insert(problems_.begin(), hint);
		return false;
	}

	trans_ = solver_create_transaction(solv_);
	transaction_order(trans_, 0);
	return true;
}

Id resolver::best_available_id(const string& name) const
{
	Id nameid = pool_str2id(pool_, name.c_str(), 0);
	Id best = 0;

	if (!nameid)
		return 0;

	for (size_t r = 0; r < repos_.size(); r++) {
		Id p;
		Solvable* s;
		FOR_REPO_SOLVABLES(repos_[r], p, s) {
			if (s->name != nameid || !pool_installable(pool_, s))
				continue;
			if (!best || pool_evrcmp(pool_, s->evr, pool_id2solvable(pool_, best)->evr, EVRCMP_COMPARE) > 0)
				best = p;
		}
	}

	return best;
}

vector<string> resolver::explain_not_upgraded(const string& name)
{
	vector<string> reasons;
	prepare();

	Id nameid = pool_str2id(pool_, name.c_str(), 0);
	Id best = best_available_id(name);
	if (!nameid || !best)
		return reasons;

	// Installed version
	Id p;
	Solvable* s;
	Id installed_evr = 0;
	FOR_REPO_SOLVABLES(installed_, p, s)
		if (s->name == nameid)
			installed_evr = s->evr;
	if (!installed_evr || pool_evrcmp(pool_, pool_id2solvable(pool_, best)->evr, installed_evr, EVRCMP_COMPARE) <= 0)
		return reasons;

	// Ask the solver to install exactly that version and report why it cannot
	Queue job;
	queue_init(&job);
	queue_push2(&job, SOLVER_SOLVABLE | SOLVER_INSTALL, best);
	Solver* alt = solver_create(pool_);
	solver_set_flag(alt, SOLVER_FLAG_ALLOW_ARCHCHANGE, 1);
	solver_set_flag(alt, SOLVER_FLAG_ALLOW_VENDORCHANGE, 1);
	if (solver_solve(alt, &job) != 0)
		collect_problems(alt, reasons);
	solver_free(alt);
	queue_free(&job);

	return reasons;
}

vector<plan_step> resolver::plan() const
{
	vector<plan_step> result;
	if (!trans_)
		return result;

	// libsolv reports a replacement from two sides: the old package is
	// "passive" (UPGRADED, OBSOLETED, ...), the new one "active" (UPGRADE,
	// OBSOLETES, ...). The passive view finds packages replaced by one with a
	// different name, the active view drives the plan.
	const int passive = SOLVER_TRANSACTION_SHOW_OBSOLETES;
	const int active = SOLVER_TRANSACTION_SHOW_ACTIVE | SOLVER_TRANSACTION_SHOW_OBSOLETES;
	map<Id, vector<Id> > obsoleted_by;
	const Queue& steps = trans_->steps;

	for (int i = 0; i < steps.count; i++) {
		Id p = steps.elements[i];
		if (transaction_type(trans_, p, passive) == SOLVER_TRANSACTION_OBSOLETED) {
			Id by = transaction_obs_pkg(trans_, p);
			if (by)
				obsoleted_by[by].push_back(p);
		}
	}

	for (int i = 0; i < steps.count; i++) {
		Id p = steps.elements[i];
		Solvable* s = pool_id2solvable(pool_, p);
		int type = transaction_type(trans_, p, active);
		plan_step step;

		step.name = pool_id2str(pool_, s->name);
		step.version = pool_id2str(pool_, s->evr);

		switch (type) {
		case SOLVER_TRANSACTION_ERASE:
			step.kind = plan_step::REMOVE;
			if (erase_targets_.find(step.name) == erase_targets_.end())
				step.note = dependency_.find(step.name) != dependency_.end()
					? "no longer needed" : "depends on a removed package";
			result.push_back(step);
			break;

		case SOLVER_TRANSACTION_INSTALL:
		case SOLVER_TRANSACTION_MULTIINSTALL:
		case SOLVER_TRANSACTION_OBSOLETES:
		case SOLVER_TRANSACTION_UPGRADE:
		case SOLVER_TRANSACTION_DOWNGRADE:
		case SOLVER_TRANSACTION_CHANGE:
		case SOLVER_TRANSACTION_REINSTALL: {
			// Packages replaced by this one under another name go first,
			// so that their files do not show up as conflicts.
			map<Id, vector<Id> >::const_iterator ob = obsoleted_by.find(p);
			if (ob != obsoleted_by.end()) {
				for (size_t k = 0; k < ob->second.size(); k++) {
					Solvable* old = pool_id2solvable(pool_, ob->second[k]);
					if (old->name == s->name)
						continue;
					plan_step rm;
					rm.kind = plan_step::REMOVE;
					rm.name = pool_id2str(pool_, old->name);
					rm.version = pool_id2str(pool_, old->evr);
					rm.note = "replaced by " + step.name;
					result.push_back(rm);
				}
			}

			step.filename = solvable_file(p);
			{
				Id chktype = 0;
				const char* chk = solvable_lookup_checksum(pool_id2solvable(pool_, p), SOLVABLE_CHECKSUM, &chktype);
				if (chk && chktype == REPOKEY_TYPE_SHA256)
					step.checksum = chk;
			}

			if (type == SOLVER_TRANSACTION_INSTALL ||
			    type == SOLVER_TRANSACTION_OBSOLETES ||
			    type == SOLVER_TRANSACTION_MULTIINSTALL) {
				step.kind = plan_step::INSTALL;
			} else {
				step.kind = plan_step::UPGRADE;
				Id old = transaction_obs_pkg(trans_, p);
				if (old)
					step.old_version = pool_id2str(pool_, pool_id2solvable(pool_, old)->evr);
			}
			result.push_back(step);
			break;
		}

		default:
			// IGNORE: the replaced side of an upgrade or replacement
			break;
		}
	}

	return result;
}

string resolver::best_available(const string& name) const
{
	Id best = best_available_id(name);
	return best ? pool_id2str(pool_, pool_id2solvable(pool_, best)->evr) : string();
}

bool resolver::newer(const string& a, const string& b) const
{
	return pool_evrcmp_str(pool_, a.c_str(), b.c_str(), EVRCMP_COMPARE) > 0;
}
