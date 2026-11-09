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

int main(void) {
    unsigned char seed[32];
    PCREDENTIALW saved = NULL;
    const wchar_t *target = L"org.opensound.parvi.native-identity/device-v1";
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
    int ok = fwrite(seed, 1, sizeof(seed), stdout) == sizeof(seed);
    SecureZeroMemory(seed, sizeof(seed));
    return ok ? 0 : 1;
}
