#pragma once
#include <stdint.h>
int ba_bridge_listen(uint16_t *port);
int ba_bridge_accept(int listener);
void ba_beam_start(const char *root, const char *data_directory, uint16_t port);
