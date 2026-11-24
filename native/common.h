#pragma once
#include <windows.h>
#include <cstdint>
#include <string>
#include <vector>

typedef std::vector<uint8_t> Bytes;

// util.cpp
void LogOpen(const std::wstring& path);
void Log(const char* fmt, ...);
bool ReadWholeFile(const std::wstring& path, Bytes& out);
bool WriteFileAtomic(const std::wstring& path, const std::string& data);
bool FileStamp(const std::wstring& path, uint64_t& size, uint64_t& mtime);
std::wstring DirName(const std::wstring& path);
std::string Narrow(const std::wstring& s);

// crypto.cpp (Windows CNG)
bool AesEcbDecrypt(const uint8_t key[32], uint8_t* data, size_t len);
bool AesCbcDecrypt(const uint8_t key[32], const uint8_t iv[16], const uint8_t* in, uint8_t* out, size_t len);
bool Pbkdf2Sha512(const uint8_t* pass, size_t passLen, const uint8_t* salt, size_t saltLen, uint32_t iterations, uint8_t* out, size_t outLen);
bool HmacSha512(const uint8_t* key, size_t keyLen, const uint8_t* a, size_t aLen, const uint8_t* b, size_t bLen, uint8_t out[64]);

// pak.cpp: extracts SectionTreasureBoxData.xml from the game's paks and writes the Lua catalog.
bool BuildTreasureCatalog(const std::wstring& exePath, const std::wstring& pakDir, const std::wstring& outFile, const std::string& version, std::string& err);
std::string GameDataVersion(const std::wstring& exePath, const std::wstring& pakDir);

// save.cpp: reads opened chests and finished random quests from the encrypted save.
struct SaveState {
    std::vector<int64_t> openedChests;
    std::vector<int64_t> finishedQuests;
};
enum SaveResult { SAVE_OK, SAVE_BAD_KEY, SAVE_BUSY, SAVE_ERROR };
SaveResult ReadSave(const Bytes& file, const std::string& passphrase, SaveState& out, std::string& err);
bool SaveKeyMatches(const Bytes& file, const std::string& passphrase);
std::vector<std::string> FindKeyCandidates(size_t maxCandidates);
