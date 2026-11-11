/* Minimal in-process OTP host. Startup/ABI reference: GenericJam/mob,
 * MIT Copyright (c) 2026 Kevin Smith. See docs/apps/iOS/THIRD_PARTY.md.
 * BEAM Audio-specific loopback UI bridge; no Mob framework or hot-code loading. */
#include "ba_beam.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>

typedef struct { void *entry; int flags; } StaticDriver;
typedef struct { void *(*init)(void); int builtin; unsigned long module; void *entry; } StaticNif;
extern char inet_driver_entry, ram_file_driver_entry;
extern void *prim_tty_nif_init(void), *erl_tracer_nif_init(void);
extern void *prim_buffer_nif_init(void), *prim_file_nif_init(void);
extern void *zlib_nif_init(void), *zstd_nif_init(void);
extern void *prim_socket_nif_init(void), *prim_net_nif_init(void);
extern void *asn1rt_nif_nif_init(void), *crypto_nif_init(void);
#ifdef BA_NATIVE_TRANSPORT
extern void *ba_dtls_nif_init(void), *ba_srtp_nif_init(void);
extern void *ba_crc_nif_init(void), *ex_sctp_nif_init(void);
#endif

StaticDriver driver_tab[] = {{&inet_driver_entry, 0}, {&ram_file_driver_entry, 0}, {NULL, 0}};
void erts_init_static_drivers(void) {}
StaticNif erts_static_nif_tab[] = {
    {prim_tty_nif_init, 0, 0, NULL}, {erl_tracer_nif_init, 0, 0, NULL},
    {prim_buffer_nif_init, 0, 0, NULL}, {prim_file_nif_init, 0, 0, NULL},
    {zlib_nif_init, 0, 0, NULL}, {zstd_nif_init, 0, 0, NULL},
    {prim_socket_nif_init, 0, 0, NULL}, {prim_net_nif_init, 0, 0, NULL},
    {asn1rt_nif_nif_init, 1, 0, NULL}, {crypto_nif_init, 1, 0, NULL},
#ifdef BA_NATIVE_TRANSPORT
    {ba_dtls_nif_init, 1, 0, NULL}, {ba_srtp_nif_init, 1, 0, NULL},
    {ba_crc_nif_init, 1, 0, NULL}, {ex_sctp_nif_init, 1, 0, NULL},
#endif
    {NULL, 0, 0, NULL}
};
/* Compatibility helper needed by the pinned device archive's errno object. */
__attribute__((weak)) const char *erl_errno_id_unknown(int error) { (void)error; return "unknown"; }

int ba_bridge_listen(uint16_t *port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) || listen(fd, 1)) {
        close(fd); return -1;
    }
    socklen_t size = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &size)) { close(fd); return -1; }
    *port = ntohs(address.sin_port);
    return fd;
}
int ba_bridge_accept(int listener) { return accept(listener, NULL, NULL); }

void ba_beam_start(const char *root, const char *data_directory, uint16_t port) {
    static atomic_bool started = 0;
    if (atomic_exchange(&started, 1)) return; /* BEAM cannot start twice in a process. */
    char bindir[2048], boot[2048], beams[2048], dump[2048], proof[2048], port_string[16];
    snprintf(bindir, sizeof(bindir), "%s/erts-17.1.1/bin", root);
    snprintf(boot, sizeof(boot), "%s/start_clean", root);
    snprintf(beams, sizeof(beams), "%s/lib/ba_core-0.1.0/ebin", root);
    snprintf(dump, sizeof(dump), "%s/ba_erl_crash.dump", data_directory);
    snprintf(proof, sizeof(proof), "%s/ba_runtime_proof.json", data_directory);
    snprintf(port_string, sizeof(port_string), "%u", port);
    setenv("ROOTDIR", root, 1);
    setenv("BINDIR", bindir, 1);
    setenv("PROGNAME", "erl", 1);
    setenv("EMU", "beam", 1);
    setenv("ERL_CRASH_DUMP", dump, 1);
    setenv("BA_BRIDGE_PORT", port_string, 1);
    setenv("BA_PROOF_PATH", proof, 1);
    const char *values[] = {"beam", "-S", "1:1", "-SDcpu", "1:1", "-SDio", "1", "-A", "1",
        "-sbwt", "none", "-MIscs", "128", "--", "-root", root,
        "-bindir", bindir, "-progname", "erl", "--", "-noshell", "-noinput",
        "-start_epmd", "false", "-boot", boot, "-pa", beams,
        "-ba_core", "runtime_profile", "buffee_control",
        "-s", "ba_ios", "main", NULL};
    int count = 0;
    while (values[count]) count++;
    char **args = calloc((size_t)count + 1, sizeof(char *));
    for (int i = 0; i < count; i++) args[i] = strdup(values[i]);
    extern void erl_start(int, char **);
    erl_start(count, args); /* Never returns during normal operation. */
}
