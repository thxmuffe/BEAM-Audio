#pragma once
#include <stdint.h>
int parvi_bridge_listen(uint16_t *port);
int parvi_bridge_accept(int listener);
void parvi_beam_start(const char *root, const char *data_directory, uint16_t port);
