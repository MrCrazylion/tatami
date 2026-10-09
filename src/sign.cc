#include "sign.h"
#include "util.h"
#include <sodium.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

typedef unsigned char u8;

int hex_value(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

bool hex_decode(const string& s, u8* out, size_t size)
{
	if (s.size() != size * 2)
		return false;
	for (size_t i = 0; i < size; i++) {
		const int hi = hex_value(s[2 * i]), lo = hex_value(s[2 * i + 1]);
		if (hi < 0 || lo < 0)
			return false;
		out[i] = (u8)(hi * 16 + lo);
	}
	return true;
}

bool base64_decode(const string& s, vector<u8>& out)
{
	static const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	size_t end = s.size();
	while (end > 0 && s[end - 1] == '=')
		end--;
	if (s.size() - end > 2)
		return false;

	unsigned int acc = 0;
	int bits = 0;
	out.clear();
	for (size_t i = 0; i < end; i++) {
		const string::size_type v = alphabet.find(s[i]);
		if (v == string::npos)
			return false;
		acc = (acc << 6) | (unsigned int)v;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			out.push_back((u8)((acc >> bits) & 0xff));
		}
	}
	return true;
}

// Feeds a file to an Ed25519ph state (it hashes with SHA-512), in pieces
void file_feed(const string& file, crypto_sign_ed25519ph_state* st)
{
	FILE* fp = fopen(file.c_str(), "rb");
	if (!fp)
		throw runtime_error_with_errno("could not open " + file);

	crypto_sign_ed25519ph_init(st);
	u8 buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, fp)) > 0)
		crypto_sign_ed25519ph_update(st, buf, n);
	const bool failed = ferror(fp);
	fclose(fp);
	if (failed)
		throw runtime_error("could not read " + file);
}

void init_sodium()
{
	if (sodium_init() < 0)
		throw runtime_error("could not initialize libsodium");
}

string slurp_line(const string& file)
{
	FILE* fp = fopen(file.c_str(), "r");
	if (!fp)
		throw runtime_error_with_errno("could not open " + file);
	char buf[1024];
	const size_t n = fread(buf, 1, sizeof buf - 1, fp);
	fclose(fp);
	buf[n] = 0;
	return trim(string(buf));
}

void wipe(void* p, size_t n)
{
	sodium_memzero(p, n);
}

string home_dir()
{
	const char* h = getenv("HOME");
	if (h && *h)
		return h;
	struct passwd* pw = getpwuid(getuid());
	if (pw && pw->pw_dir && *pw->pw_dir)
		return pw->pw_dir;
	throw runtime_error("cannot find the home directory (set HOME, or name the key file)");
}

// The private key of a command: the argument, TATAMI_PRIVKEY, ~/.tatami/privkey
string default_privkey()
{
	const char* e = getenv("TATAMI_PRIVKEY");
	if (e && *e)
		return e;
	return home_dir() + "/.tatami/privkey";
}

void read_seed(const string& file, u8 seed[32])
{
	struct stat st;
	if (stat(file.c_str(), &st) == -1)
		throw runtime_error_with_errno("could not open private key " + file);
	if (st.st_mode & 077)
		cerr << "tatami: warning: private key " << file << " is accessible by others (chmod 600 it)" << endl;
	if (!hex_decode(slurp_line(file), seed, 32))
		throw runtime_error(file + " is not a tatami private key (expected 64 hex digits)");
}

void random_bytes(u8* out, size_t size)
{
	init_sodium();
	randombytes_buf(out, size);        // the operating system's generator
}

void write_new_file(const string& file, const string& content, mode_t mode, bool overwrite)
{
	const int fd = open(file.c_str(), O_WRONLY | O_CREAT | (overwrite ? O_TRUNC : O_EXCL), mode);
	if (fd == -1)
		throw runtime_error_with_errno("could not create " + file);
	size_t done = 0;
	while (done < content.size()) {
		const ssize_t n = write(fd, content.data() + done, content.size() - done);
		if (n == -1 && errno == EINTR)
			continue;
		if (n <= 0) {
			const int e = errno;
			close(fd);
			throw runtime_error_with_errno("could not write " + file, e);
		}
		done += (size_t)n;
	}
	if (fsync(fd) == -1 || close(fd) == -1)
		throw runtime_error_with_errno("could not write " + file);
}

string dir_of(const string& path)
{
	const string::size_type slash = path.rfind('/');
	return slash == string::npos ? "." : slash == 0 ? "/" : path.substr(0, slash);
}

}

string hex_encode(const unsigned char* data, size_t size)
{
	static const char digits[] = "0123456789abcdef";
	string s;
	for (size_t i = 0; i < size; i++) {
		s += digits[data[i] >> 4];
		s += digits[data[i] & 15];
	}
	return s;
}

bool decode_pubkey(const string& text, unsigned char out[32])
{
	const string t = trim(text);
	if (hex_decode(t, out, 32))
		return true;
	vector<u8> raw;
	if (!base64_decode(t, raw) || raw.size() != 32)
		return false;
	memcpy(out, &raw[0], 32);
	return true;
}

string file_sha256(const string& file)
{
	init_sodium();
	FILE* fp = fopen(file.c_str(), "rb");
	if (!fp)
		throw runtime_error_with_errno("could not open " + file);

	crypto_hash_sha256_state st;
	crypto_hash_sha256_init(&st);
	u8 buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, fp)) > 0)
		crypto_hash_sha256_update(&st, buf, n);
	const bool failed = ferror(fp);
	fclose(fp);
	if (failed)
		throw runtime_error("could not read " + file);

	u8 hash[crypto_hash_sha256_BYTES];
	crypto_hash_sha256_final(&st, hash);
	return hex_encode(hash, sizeof hash);
}

string sign_file(const string& file, const unsigned char seed[32])
{
	init_sodium();
	u8 pk[crypto_sign_ed25519_PUBLICKEYBYTES], sk[crypto_sign_ed25519_SECRETKEYBYTES], sig[64];
	crypto_sign_ed25519_seed_keypair(pk, sk, seed);

	crypto_sign_ed25519ph_state st;
	file_feed(file, &st);
	unsigned long long siglen = 0;
	if (crypto_sign_ed25519ph_final_create(&st, sig, &siglen, sk) != 0 || siglen != 64) {
		wipe(sk, sizeof sk);
		throw runtime_error("could not sign " + file);
	}
	wipe(sk, sizeof sk);

	// never write a signature that does not verify
	crypto_sign_ed25519ph_state check;
	file_feed(file, &check);
	if (crypto_sign_ed25519ph_final_verify(&check, sig, pk) != 0)
		throw runtime_error("internal error: the signature of " + file + " does not verify");
	return hex_encode(sig, 64);
}

void verify_file(const string& file, const string& sigfile, const unsigned char pubkey[32])
{
	string text;
	try {
		text = slurp_line(sigfile);
	} catch (runtime_error&) {
		throw signature_error("no signature for " + file + " (" + sigfile + " is missing)");
	}
	u8 sig[64];
	if (!hex_decode(text, sig, 64))
		throw signature_error(sigfile + " is not a signature");

	init_sodium();
	crypto_sign_ed25519ph_state st;
	file_feed(file, &st);
	if (crypto_sign_ed25519ph_final_verify(&st, sig, pubkey) != 0)
		throw signature_error("SIGNATURE VERIFICATION FAILED for " + file +
				      ": it was not signed with the key in PUBKEY");
}

int keygen_main(int argc, char** argv)
{
	try {
		bool force = false;
		string priv;
		for (int i = 2; i < argc; i++) {
			const string a = argv[i];
			if (a == "-f" || a == "--force")
				force = true;
			else if (a == "-h" || a == "--help") {
				cout << "usage: tatami keygen [-f] [private-key-file]\n"
					"  makes an Ed25519 key pair; the private key goes to the file (default\n"
					"  $TATAMI_PRIVKEY or ~/.tatami/privkey, mode 600), the public key to <file>.pub.\n"
					"  Put the public key into tatami.conf as PUBKEY = <key>." << endl;
				return 0;
			} else if (!a.empty() && a[0] == '-')
				throw runtime_error("invalid option " + a);
			else if (priv.empty())
				priv = a;
			else
				throw runtime_error("too many arguments");
		}
		if (priv.empty())
			priv = default_privkey();

		if (!force && access(priv.c_str(), F_OK) == 0)
			throw runtime_error(priv + " already exists (use -f to replace it: packages signed with the old key will no longer verify)");

		const string dir = dir_of(priv);
		if (access(dir.c_str(), F_OK) != 0)
			mkdir_p(dir, 0700);

		u8 seed[32], sk[crypto_sign_ed25519_SECRETKEYBYTES], pk[crypto_sign_ed25519_PUBLICKEYBYTES];
		random_bytes(seed, 32);
		crypto_sign_ed25519_seed_keypair(pk, sk, seed);
		wipe(sk, sizeof sk);

		if (force)
			unlink(priv.c_str());
		write_new_file(priv, hex_encode(seed, 32) + "\n", 0600, false);
		wipe(seed, sizeof seed);
		const string pub = hex_encode(pk, 32);
		write_new_file(priv + ".pub", pub + "\n", 0644, true);

		cout << "Private key: " << priv << " (keep it secret)" << endl;
		cout << "Public key:  " << priv << ".pub" << endl;
		cout << "Add this to tatami.conf on every machine that installs your packages:" << endl;
		cout << "PUBKEY = " << pub << endl;
	} catch (runtime_error& e) {
		cerr << "tatami: " << e.what() << endl;
		return 1;
	}
	return 0;
}

int sign_main(int argc, char** argv)
{
	try {
		vector<string> args;
		for (int i = 2; i < argc; i++) {
			const string a = argv[i];
			if (a == "-h" || a == "--help") {
				cout << "usage: tatami sign <file> [private-key-file]\n"
					"  writes <file>.sig (an Ed25519 signature of the file). The key defaults\n"
					"  to $TATAMI_PRIVKEY or ~/.tatami/privkey." << endl;
				return 0;
			}
			args.push_back(a);
		}
		if (args.empty() || args.size() > 2)
			throw runtime_error("usage: tatami sign <file> [private-key-file]");

		u8 seed[32];
		read_seed(args.size() > 1 ? args[1] : default_privkey(), seed);
		const string sig = sign_file(args[0], seed);
		wipe(seed, sizeof seed);

		const string out = args[0] + ".sig";
		write_new_file(out + ".tmp", sig + "\n", 0644, true);
		if (rename((out + ".tmp").c_str(), out.c_str()) == -1) {
			const int e = errno;
			unlink((out + ".tmp").c_str());
			throw runtime_error_with_errno("could not write " + out, e);
		}
		cout << "Signed " << args[0] << " -> " << out << endl;
	} catch (runtime_error& e) {
		cerr << "tatami: " << e.what() << endl;
		return 1;
	}
	return 0;
}
