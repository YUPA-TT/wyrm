#pragma once
/* Custom tags, Swift side. Main thread only. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Saves the picture the engine draws as the player's own tag: a PNG already
   turned the way Wyrm's tags are stored (top towards the rope). Returns false
   if the data is not a PNG or cannot be saved. */
bool WyrmCustomTagSetImage(const uint8_t* png, size_t length);

/* use_image: draw the saved picture instead of the chosen tag.
   use_colors: draw the rope in c1 (thick line) and c2 (tip), 0xRRGGBB.
   scale: 1 is the tag's own size. along / across: how far to move the tag from
   where it hangs, as a fraction of its own width (along the rope, away from the
   head) and height (across it). 0 and 0 is where it hangs by default.
   Saved by the engine, so it is still in force after a restart. */
void WyrmCustomTagConfigure(bool use_image, bool use_colors, uint32_t c1,
                            uint32_t c2, float scale, float along,
                            float across);

/* What the engine made of the picture. Returns 0 when there is none yet, 1 when
   it is ready, -1 when it could not be read. `text` gets a short description. */
int WyrmCustomTagStatus(char* text, size_t capacity);
