#include "meta.h"
#include "util.h"
#include <fstream>
#include <sstream>
#include <cstdlib>
#include <cctype>

bool read_meta_block(istream& in, pkgmeta& meta)
{
	string line;
	bool any = false;

	meta = pkgmeta();

	while (getline(in, line)) {
		if (trim(line).empty()) {
			if (any)
				break;
			continue;
		}
		if (line[0] == '#')
			continue;

		string::size_type colon = line.find(':');
		if (colon == string::npos)
			throw runtime_error("malformed metadata line: " + line);

		string key = trim(line.substr(0, colon));
		const string value = trim(line.substr(colon + 1));
		for (string::size_type i = 0; i < key.size(); i++)
			key[i] = tolower((unsigned char)key[i]);

		if (key == "name")
			meta.name = value;
		else if (key == "version")
			meta.version = value;
		else if (key == "arch")
			meta.arch = value;
		else if (key == "description")
			meta.description = value;
		else if (key == "depends")
			meta.depends = value;
		else if (key == "conflicts")
			meta.conflicts = value;
		else if (key == "provides")
			meta.provides = value;
		else if (key == "replaces")
			meta.replaces = value;
		else if (key == "filename")
			meta.filename = value;
		else if (key == "reason")
			meta.reason = value;
		else if (key == "size")
			meta.size = strtoull(value.c_str(), 0, 10);
		// unknown keys are ignored so that the format can grow

		any = true;
	}

	return any;
}

pkgmeta parse_meta(const string& text)
{
	istringstream in(text);
	pkgmeta meta;

	read_meta_block(in, meta);
	return meta;
}

static void put(ostream& out, const char* key, const string& value)
{
	if (!value.empty()) {
		// Values are single line
		string v = value;
		for (string::size_type i = 0; i < v.size(); i++)
			if (v[i] == '\n' || v[i] == '\r')
				v[i] = ' ';
		out << key << ": " << v << "\n";
	}
}

string format_meta(const pkgmeta& meta)
{
	ostringstream out;

	put(out, "name", meta.name);
	put(out, "version", meta.version);
	put(out, "arch", meta.arch);
	put(out, "description", meta.description);
	put(out, "depends", meta.depends);
	put(out, "conflicts", meta.conflicts);
	put(out, "provides", meta.provides);
	put(out, "replaces", meta.replaces);
	put(out, "filename", meta.filename);
	put(out, "reason", meta.reason);
	if (meta.size)
		out << "size: " << meta.size << "\n";

	return out.str();
}

static bool all_of_chars(const string& s, const string& extra)
{
	for (string::size_type i = 0; i < s.size(); i++)
		if (!isalnum((unsigned char)s[i]) && extra.find(s[i]) == string::npos)
			return false;
	return true;
}

void validate_meta(const pkgmeta& meta)
{
	if (meta.name.empty())
		throw runtime_error("package metadata has no name");
	if (meta.version.empty())
		throw runtime_error("package metadata has no version");
	// '_' separates name and version in package file names, so it is reserved
	if (!isalnum((unsigned char)meta.name[0]) || !all_of_chars(meta.name, "+.-"))
		throw runtime_error("invalid package name '" + meta.name + "'");
	if (!isalnum((unsigned char)meta.version[0]) || !all_of_chars(meta.version, "+.~:-"))
		throw runtime_error("invalid version '" + meta.version + "' for package " + meta.name);
}

vector<pkgmeta> read_index(const string& filename)
{
	vector<pkgmeta> result;
	ifstream in(filename.c_str());

	if (!in)
		return result;

	pkgmeta meta;
	try {
		while (read_meta_block(in, meta)) {
			validate_meta(meta);
			result.push_back(meta);
		}
	} catch (runtime_error& e) {
		throw runtime_error(filename + ": " + e.what() + " (the index is corrupt, try 'tatami update')");
	}

	return result;
}
