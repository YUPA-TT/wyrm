#pragma once
/* Custom tags (Swift side). Main thread only. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Stores the picture the engine draws as the player's own tag: a PNG already
   turned the way Wyrm's tags are stored (top towards the rope). Returns false
   if the data is not a PNG or cannot be saved. */
bool WyrmCustomTagSetImage(const uint8_t* png, size_t length);

/* use_image: draw the saved picture instead of the chosen tag.
   use_colors: draw the rope in c1 (thick line) and c2 (tip), 0xRRGGBB.
   Saved by the engine, so it is still in force after a restart. */
void WyrmCustomTagConfigure(bool use_image, bool use_colors, uint32_t c1,
                            uint32_t c2);
