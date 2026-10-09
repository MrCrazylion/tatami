#ifndef SIGN_H
#define SIGN_H

#include <stdexcept>
#include <string>

using namespace std;

// Package and index signing: Ed25519 (RFC 8032, the pre-hash variant Ed25519ph, so
// files of any size are signed through their SHA-512 digest), done by libsodium
// (a git submodule in deps/, linked statically). No OpenSSL or other host library.
//
//   tatami keygen [-f] [private-key-file]      makes a key pair (default ~/.tatami/privkey)
//   tatami sign <file> [private-key-file]      writes <file>.sig
//
// A private key file holds the 32-byte seed as 64 hex digits; a public key is
// 32 bytes, written as 64 hex digits (PUBKEY in tatami.conf also takes base64).
// A .sig file holds the 64-byte signature as 128 hex digits.

// A signature that is missing, malformed or does not match
struct signature_error : public runtime_error {
	explicit signature_error(const string& what) : runtime_error(what) {}
};

string hex_encode(const unsigned char* data, size_t size);

// SHA-256 of a file, in hex (libsodium), read in pieces. Used for the package
// checksums of repo.solv.
string file_sha256(const string& file);

// Hex (64 digits) or base64 (32 bytes) to 32 bytes. False if it is neither.
bool decode_pubkey(const string& text, unsigned char out[32]);

// Signs 'file'; returns the signature as 128 hex digits
string sign_file(const string& file, const unsigned char seed[32]);

// Checks 'file' against the signature in 'sigfile'. Throws signature_error.
void verify_file(const string& file, const string& sigfile, const unsigned char pubkey[32]);

// Entry points of  tatami keygen  and  tatami sign  (no configuration, no root)
int keygen_main(int argc, char** argv);
int sign_main(int argc, char** argv);

#endif /* SIGN_H */
