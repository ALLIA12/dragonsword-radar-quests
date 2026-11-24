#include "common.h"
#include <bcrypt.h>
#include <mutex>

static BCRYPT_ALG_HANDLE g_aesEcb, g_aesCbc, g_hmac512;
static std::once_flag g_init;

static void Init() {
    if (BCryptOpenAlgorithmProvider(&g_aesEcb, BCRYPT_AES_ALGORITHM, nullptr, 0) == 0)
        BCryptSetProperty(g_aesEcb, BCRYPT_CHAINING_MODE, (PUCHAR)BCRYPT_CHAIN_MODE_ECB, sizeof(BCRYPT_CHAIN_MODE_ECB), 0);
    if (BCryptOpenAlgorithmProvider(&g_aesCbc, BCRYPT_AES_ALGORITHM, nullptr, 0) == 0)
        BCryptSetProperty(g_aesCbc, BCRYPT_CHAINING_MODE, (PUCHAR)BCRYPT_CHAIN_MODE_CBC, sizeof(BCRYPT_CHAIN_MODE_CBC), 0);
    BCryptOpenAlgorithmProvider(&g_hmac512, BCRYPT_SHA512_ALGORITHM, nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG);
}

static bool Aes(BCRYPT_ALG_HANDLE alg, const uint8_t key[32], uint8_t* iv, const uint8_t* in, uint8_t* out, size_t len) {
    if (len % 16 != 0) return false;
    BCRYPT_KEY_HANDLE k = nullptr;
    if (BCryptGenerateSymmetricKey(alg, &k, nullptr, 0, (PUCHAR)key, 32, 0) != 0) return false;
    ULONG got = 0;
    NTSTATUS s = BCryptDecrypt(k, (PUCHAR)in, (ULONG)len, nullptr, iv, iv ? 16 : 0, out, (ULONG)len, &got, 0);
    BCryptDestroyKey(k);
    return s == 0 && got == len;
}

bool AesEcbDecrypt(const uint8_t key[32], uint8_t* data, size_t len) {
    std::call_once(g_init, Init);
    return Aes(g_aesEcb, key, nullptr, data, data, len);
}

bool AesCbcDecrypt(const uint8_t key[32], const uint8_t iv[16], const uint8_t* in, uint8_t* out, size_t len) {
    std::call_once(g_init, Init);
    uint8_t ivCopy[16];
    memcpy(ivCopy, iv, 16);
    return Aes(g_aesCbc, key, ivCopy, in, out, len);
}

bool Pbkdf2Sha512(const uint8_t* pass, size_t passLen, const uint8_t* salt, size_t saltLen, uint32_t iterations, uint8_t* out, size_t outLen) {
    std::call_once(g_init, Init);
    return BCryptDeriveKeyPBKDF2(g_hmac512, (PUCHAR)pass, (ULONG)passLen, (PUCHAR)salt, (ULONG)saltLen, iterations, out, (ULONG)outLen, 0) == 0;
}

bool HmacSha512(const uint8_t* key, size_t keyLen, const uint8_t* a, size_t aLen, const uint8_t* b, size_t bLen, uint8_t out[64]) {
    std::call_once(g_init, Init);
    BCRYPT_HASH_HANDLE h = nullptr;
    if (BCryptCreateHash(g_hmac512, &h, nullptr, 0, (PUCHAR)key, (ULONG)keyLen, 0) != 0) return false;
    bool ok = BCryptHashData(h, (PUCHAR)a, (ULONG)aLen, 0) == 0 &&
              (bLen == 0 || BCryptHashData(h, (PUCHAR)b, (ULONG)bLen, 0) == 0) &&
              BCryptFinishHash(h, out, 64, 0) == 0;
    BCryptDestroyHash(h);
    return ok;
}
