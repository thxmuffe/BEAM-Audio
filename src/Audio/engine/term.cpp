// Erlang external term format <-> the engine's in-memory messages, using OTP's
// own ei library (erl_interface), as the OTP interoperability guide recommends
// for port programs. Erlang sends term_to_binary(Map); replies decode with
// binary_to_term. Maps with atom keys become objects, binaries strings, lists
// and tuples arrays; true/false are booleans and undefined is null.
#include <ei.h>

#include <stdexcept>
#include <string>

#include "engine.h"
#include "term.h"

namespace ba {
namespace {
[[noreturn]] void bad(const char *what) { throw std::logic_error(std::string("invalid control term: ") + what); }

json decode_term(const char *buf, int *index) {
    int type = 0, size = 0;
    if (ei_get_type(buf, index, &type, &size)) bad("type");
    switch (type) {
        case ERL_SMALL_INTEGER_EXT:
        case ERL_INTEGER_EXT:
        case ERL_SMALL_BIG_EXT:
        case ERL_LARGE_BIG_EXT: {
            long long v = 0;
            if (!ei_decode_longlong(buf, index, &v)) return v;
            unsigned long long u = 0;
            if (ei_decode_ulonglong(buf, index, &u)) bad("integer out of 64-bit range");
            return u;
        }
        case NEW_FLOAT_EXT:
        case ERL_FLOAT_EXT: {
            double v = 0;
            if (ei_decode_double(buf, index, &v)) bad("float");
            return v;
        }
        case ERL_ATOM_EXT:
        case ERL_SMALL_ATOM_EXT:
        case ERL_ATOM_UTF8_EXT:
        case ERL_SMALL_ATOM_UTF8_EXT: {
            char atom[MAXATOMLEN_UTF8];
            if (ei_decode_atom(buf, index, atom)) bad("atom");
            const std::string a(atom);
            if (a == "true") return true;
            if (a == "false") return false;
            if (a == "undefined") return nullptr;
            return a;
        }
        case ERL_BINARY_EXT: {
            std::string s(size_t(size), '\0');
            long length = 0;
            if (ei_decode_binary(buf, index, s.data(), &length)) bad("binary");
            return s;
        }
        case ERL_NIL_EXT:
        case ERL_LIST_EXT:
        case ERL_STRING_EXT: {
            if (type == ERL_STRING_EXT) bad("charlist; send binaries");
            int arity = 0;
            if (ei_decode_list_header(buf, index, &arity)) bad("list");
            json list = json::array();
            for (int i = 0; i < arity; ++i) list.push_back(decode_term(buf, index));
            if (arity && ei_decode_list_header(buf, index, &arity)) bad("improper list");
            return list;
        }
        case ERL_SMALL_TUPLE_EXT:
        case ERL_LARGE_TUPLE_EXT: {
            int arity = 0;
            if (ei_decode_tuple_header(buf, index, &arity)) bad("tuple");
            json list = json::array();
            for (int i = 0; i < arity; ++i) list.push_back(decode_term(buf, index));
            return list;
        }
        case ERL_MAP_EXT: {
            int arity = 0;
            if (ei_decode_map_header(buf, index, &arity)) bad("map");
            json object = json::object();
            for (int i = 0; i < arity; ++i) {
                const json key = decode_term(buf, index);
                if (!key.is_string()) bad("map key must be an atom or binary");
                object[key.get<std::string>()] = decode_term(buf, index);
            }
            return object;
        }
        default:
            bad("unsupported term type");
    }
}

void encode_term(ei_x_buff *x, const json &v) {
    int r = 0;
    switch (v.type()) {
        case json::value_t::object:
            r = ei_x_encode_map_header(x, long(v.size()));
            for (auto it = v.begin(); !r && it != v.end(); ++it) {
                r = ei_x_encode_atom(x, it.key().c_str());
                if (!r) encode_term(x, it.value());
            }
            break;
        case json::value_t::array:
            if (!v.empty()) r = ei_x_encode_list_header(x, long(v.size()));
            for (const auto &e : v) encode_term(x, e);
            if (!r) r = ei_x_encode_empty_list(x);
            break;
        case json::value_t::string: {
            const auto &s = v.get_ref<const std::string &>();
            r = ei_x_encode_binary(x, s.data(), int(s.size()));
            break;
        }
        case json::value_t::boolean:
            r = ei_x_encode_atom(x, v.get<bool>() ? "true" : "false");
            break;
        case json::value_t::null:
            r = ei_x_encode_atom(x, "undefined");
            break;
        case json::value_t::number_unsigned:
            r = ei_x_encode_ulonglong(x, v.get<unsigned long long>());
            break;
        case json::value_t::number_integer:
            r = ei_x_encode_longlong(x, v.get<long long>());
            break;
        case json::value_t::number_float:
            r = ei_x_encode_double(x, v.get<double>());
            break;
        default:
            bad("unencodable value");
    }
    if (r) bad("encode failed");
}
}  // namespace

void term_init() {
    if (ei_init()) throw std::runtime_error("ei_init failed");
}

json decode(const std::vector<uint8_t> &frame) {
    int index = 0, version = 0;
    const char *buf = reinterpret_cast<const char *>(frame.data());
    if (ei_decode_version(buf, &index, &version)) bad("version header");
    json v = decode_term(buf, &index);
    if (size_t(index) != frame.size()) bad("trailing bytes");
    return v;
}

std::string encode(const json &v) {
    ei_x_buff x;
    if (ei_x_new_with_version(&x)) throw std::runtime_error("ei_x_new_with_version failed");
    encode_term(&x, v);
    std::string out(x.buff, size_t(x.index));
    ei_x_free(&x);
    return out;
}
}  // namespace ba
