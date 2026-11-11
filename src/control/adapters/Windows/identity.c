/* Windows credential storage only; Erlang derives identity and owns membership. */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wincred.h>
#include <bcrypt.h>
#include <stdio.h>
#include <string.h>
#include <io.h>
#include <fcntl.h>

int main(int argc, char **argv) {
    int lease_mode = argc == 2 && strcmp(argv[1], "--lease") == 0;
    HANDLE lease = NULL;
    unsigned int slot = 1;
    unsigned char seed[32];
    PCREDENTIALW saved = NULL;
    wchar_t target[256];
    if (lease_mode) {
        // The helper owns a per-user runtime slot until its parent's stdin closes.
        wchar_t user[256]; DWORD length = 256;
        if (!GetUserNameW(user, &length)) return 1;
        for (slot = 1; slot <= 100; ++slot) {
            wchar_t name[512];
            swprintf_s(name, 512, L"Local\\OpenSound.Device.%s.%u", user, slot);
            lease = CreateMutexW(NULL, TRUE, name);
            if (!lease) return 1;
            if (GetLastError() != ERROR_ALREADY_EXISTS) break;
            CloseHandle(lease); lease = NULL;
        }
        if (!lease) return 1;
    }
    if (slot == 1) wcscpy_s(target, 256, L"org.opensound.beamaudio.native-identity/device-v1");
    else swprintf_s(target, 256, L"org.opensound.beamaudio.native-identity/device-v1-%u", slot);
    if (CredReadW(target, CRED_TYPE_GENERIC, 0, &saved)) {
        if (saved->CredentialBlobSize != sizeof(seed)) { CredFree(saved); return 1; }
        memcpy(seed, saved->CredentialBlob, sizeof(seed));
        CredFree(saved);
    } else {
        if (GetLastError() != ERROR_NOT_FOUND) return 1;
        if (BCryptGenRandom(NULL, seed, sizeof(seed), BCRYPT_USE_SYSTEM_PREFERRED_RNG)) return 1;
        CREDENTIALW value = {0};
        value.Type = CRED_TYPE_GENERIC;
        value.TargetName = (wchar_t *)target;
        value.CredentialBlobSize = sizeof(seed);
        value.CredentialBlob = seed;
        value.Persist = CRED_PERSIST_LOCAL_MACHINE;
        value.UserName = L"BEAM Audio";
        if (!CredWriteW(&value, 0)) return 1;
    }
    _setmode(_fileno(stdout), _O_BINARY);
    int ok;
    if (lease_mode) {
        unsigned char record[36] = {0, 0, 0, (unsigned char)slot};
        memcpy(record + 4, seed, sizeof(seed));
        ok = fwrite(record, 1, sizeof(record), stdout) == sizeof(record) && fflush(stdout) == 0;
        SecureZeroMemory(record, sizeof(record));
    } else ok = fwrite(seed, 1, sizeof(seed), stdout) == sizeof(seed);
    SecureZeroMemory(seed, sizeof(seed));
    if (lease) { if (ok) (void)getchar(); ReleaseMutex(lease); CloseHandle(lease); }
    return ok ? 0 : 1;
}
