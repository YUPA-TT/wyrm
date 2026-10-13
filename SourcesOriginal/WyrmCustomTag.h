#pragma once
/*
 * Custom tags (engine side). One image tag and/or one pair of rope colours,
 * for the player's own tag only; nothing here is ever sent to the arena.
 *
 * Engine-facing half: used by tags.c (patched at build time by
 * Scripts/wyrm-custom-tags-install.py) and by AppleSkinMailbox.c.
 * Everything runs on the main thread: Swift calls the setters from the UI and
 * Apple's animation callback drives the engine frame on the same thread.
 */
#include <stdbool.h>
#include <stdint.h>

typedef struct tenv tenv;
struct tag_entry;

/* Once a frame, from WyrmIOSApplySkinSelection: loads the saved setting on the
   first call and (re)builds the image texture when a new picture was written. */
void WyrmCustomTagApply(tenv* env);

/* Whether the player's own tag is drawn from the custom picture right now. */
bool wyrm_custom_tag_image_active(void);

/* The entry to draw for one snake. Returns `base` unchanged for other snakes.
   For the player's own: the custom picture's entry (filled into `out`), or a
   copy of `base` with the custom rope colours. NULL only if `base` is NULL and
   no custom picture is ready. */
const struct tag_entry* wyrm_custom_tag_entry(bool mine,
                                              const struct tag_entry* base,
                                              struct tag_entry* out);

/* Set by wyrm_custom_tag_entry for the draw that follows it. */
bool wyrm_custom_tag_drawing(void);
uintptr_t wyrm_custom_tag_descriptor(void);
