#pragma once
/*
 * Custom tags, engine side: one picture to wear as the player's own tag, rope
 * colours, and a size and position adjustment, for the player's own tag only.
 * Nothing here is ever sent to the arena: other players see whatever tag the
 * game itself announces.
 *
 * Used by tags.c (patched at build time by Scripts/wyrm-custom-tags-install.py)
 * and by AppleSkinMailbox.c. Everything runs on the main thread: Swift calls
 * the setters from the UI and the animation callback drives the engine frame
 * on the same thread.
 */
#include <stdbool.h>
#include <stdint.h>

typedef struct tenv tenv;
struct tag_entry;

/* Once a frame, from WyrmIOSApplySkinSelection: loads the saved setting on the
   first call and builds the picture's texture when a new picture was saved. */
void WyrmCustomTagApply(tenv* env);

/* Whether the player's own tag is drawn from the custom picture right now. */
bool wyrm_custom_tag_image_active(void);

/* The entry to draw for one snake. Other snakes get `base` back unchanged. For
   the player's own it is the custom picture's entry, or a copy of `base` with
   the custom rope colours and adjustment. NULL only if `base` is NULL and no
   picture is ready. The returned entry is valid until the next call. */
const struct tag_entry* wyrm_custom_tag_entry(bool mine,
                                              const struct tag_entry* base);

/* The descriptor to sample for `tag`: the custom picture's for the entry
   wyrm_custom_tag_entry made from it, `fallback` (the tag sheet) otherwise. */
uintptr_t wyrm_custom_tag_descriptor_for(const struct tag_entry* tag,
                                         uintptr_t fallback);
