/* Windows transport uses Erlang binaries, never POSIX shared-memory payloads.
 * Implement the Unifex binary payload ABI without linking the unused Shmex
 * allocator. Shared-memory inputs/allocation are explicitly unsupported. */
#include <unifex/payload.h>

ErlNifResourceType *UNIFEX_PAYLOAD_GUARD_RESOURCE_TYPE = NULL;

int unifex_payload_from_term(ErlNifEnv *env, ERL_NIF_TERM term, UnifexPayload *p) {
    if (!enif_inspect_binary(env, term, &p->payload_struct.binary)) return 0;
    p->data = p->payload_struct.binary.data;
    p->size = (unsigned int)p->payload_struct.binary.size;
    p->type = UNIFEX_PAYLOAD_BINARY;
    p->owned = 0;
    return 1;
}
UNIFEX_TERM unifex_payload_to_term(ErlNifEnv *env, UnifexPayload *p) {
    if (p->type != UNIFEX_PAYLOAD_BINARY)
        return enif_raise_exception(env, enif_make_atom(env, "unsupported_shared_memory"));
    p->owned = 0;
    return enif_make_binary(env, &p->payload_struct.binary);
}
int unifex_payload_alloc(UnifexEnv *env, UnifexPayloadType type, unsigned int size, UnifexPayload *p) {
    (void)env;
    if (type != UNIFEX_PAYLOAD_BINARY || !enif_alloc_binary(size, &p->payload_struct.binary)) return 0;
    p->data = p->payload_struct.binary.data;
    p->size = size;
    p->type = type;
    p->owned = 1;
    return 1;
}
void unifex_payload_guard_destructor(UnifexEnv *env, void *resource) { (void)env; (void)resource; }
int unifex_payload_realloc(UnifexPayload *p, unsigned int size) {
    if (p->type != UNIFEX_PAYLOAD_BINARY) return 0;
    int ok = enif_realloc_binary(&p->payload_struct.binary, size);
    if (ok) { p->size = size; p->data = p->payload_struct.binary.data; p->owned = 1; }
    return ok;
}
void unifex_payload_release(UnifexPayload *p) {
    if (p->type == UNIFEX_PAYLOAD_BINARY && p->owned) enif_release_binary(&p->payload_struct.binary);
}
