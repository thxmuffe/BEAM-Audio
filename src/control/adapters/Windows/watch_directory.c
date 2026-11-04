/* Thin ReadDirectoryChangesW binding. The Erlang host owns reload policy. */
#define _WIN32_WINNT 0x0600
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wchar.h>

static DWORD WINAPI owner_closed(void *stop) {
    char byte;
    DWORD count;
    while (ReadFile(GetStdHandle(STD_INPUT_HANDLE), &byte, 1, &count, NULL) && count) {}
    SetEvent((HANDLE)stop);
    return 0;
}

static int changed(void) {
    const unsigned char packet[] = {0, 0, 0, 1, 'c'};
    DWORD count;
    return WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), packet, sizeof(packet), &count, NULL)
        && count == sizeof(packet);
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 2) return 1;
    HANDLE directory = CreateFileW(argv[1], FILE_LIST_DIRECTORY,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
    if (directory == INVALID_HANDLE_VALUE) return 2;
    HANDLE stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    OVERLAPPED operation = {0};
    operation.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!stop || !operation.hEvent) return 3;
    HANDLE owner = CreateThread(NULL, 0, owner_closed, stop, 0, NULL);
    if (!owner) return 4;
    CloseHandle(owner);
    HANDLE events[] = {stop, operation.hEvent};
    /* DWORD alignment is required for FILE_NOTIFY_INFORMATION. */
    DWORD buffer[4096];
    int result = 0;
    for (;;) {
        ResetEvent(operation.hEvent);
        BOOL pending = ReadDirectoryChangesW(directory, buffer, sizeof(buffer), FALSE,
            FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_SIZE,
            NULL, &operation, NULL);
        if (!pending && GetLastError() != ERROR_IO_PENDING) { result = 5; break; }
        DWORD ready = WaitForMultipleObjects(2, events, FALSE, INFINITE);
        DWORD bytes = 0;
        if (ready != WAIT_OBJECT_0 + 1) {
            CancelIoEx(directory, &operation);
            GetOverlappedResult(directory, &operation, &bytes, TRUE);
            break;
        }
        if (!GetOverlappedResult(directory, &operation, &bytes, FALSE)) { result = 6; break; }
        BOOL relevant = bytes == 0; /* Overflow: ask Erlang to rescan. */
        if (bytes) {
            FILE_NOTIFY_INFORMATION *entry = (FILE_NOTIFY_INFORMATION *)buffer;
            for (;;) {
                DWORD length = entry->FileNameLength / sizeof(wchar_t);
                if (length >= 5 && _wcsnicmp(entry->FileName + length - 5, L".beam", 5) == 0)
                    relevant = TRUE;
                if (!entry->NextEntryOffset) break;
                entry = (FILE_NOTIFY_INFORMATION *)((BYTE *)entry + entry->NextEntryOffset);
            }
        }
        if (relevant && !changed()) break;
    }
    CloseHandle(directory);
    CloseHandle(operation.hEvent);
    CloseHandle(stop);
    return result;
}
