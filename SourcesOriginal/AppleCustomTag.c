#include "WyrmCustomTag.h"
#include "WyrmCustomTagBridge.h"

#include <SDL3/SDL.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "game/tag_table.h"
#include "rendering/renderer.h"
#include "user.h"

#define CUSTOM_IMAGE "custom_tag.png"
#define CUSTOM_CONFIG "custom_tag.cfg"
#define MAX_IMAGE_BYTES (4u * 1024u * 1024u)
/* The longer side of a custom picture's box, in the table's units: Wyrm's own
   boxes are about 170 to 180 across, so a picture of any resolution hangs at
   the size its neighbours do (the Size slider still scales it). */
#define BOX_LONG_SIDE 170.0f
#define BOX_ANCHOR_X 0.17f

static bool want_image;
static bool want_colors;
static uint32_t want_c1 = 0xffdaf5;
static uint32_t want_c2 = 0x8562d0;
static bool loaded;
static bool pending;
static bool config_dirty;
static unsigned dirty_frames;

static texture* image_tex;
static VkDescriptorSet image_descriptor;
static bool drawing_custom;

static void config_save(void) {
  char line[96];
  int n = snprintf(line, sizeof(line), "%d %d %u %u\n", want_image ? 1 : 0,
                   want_colors ? 1 : 0, (unsigned)want_c1, (unsigned)want_c2);
  if (n > 0 && SDL_SaveFile(CUSTOM_CONFIG, line, (size_t)n)) config_dirty = false;
}

static void config_load(void) {
  size_t size = 0;
  void* data = SDL_LoadFile(CUSTOM_CONFIG, &size);
  if (!data) return;
  char line[96] = {0};
  memcpy(line, data, size < sizeof(line) - 1 ? size : sizeof(line) - 1);
  SDL_free(data);
  int image = 0, colors = 0;
  unsigned c1 = 0, c2 = 0;
  if (sscanf(line, "%d %d %u %u", &image, &colors, &c1, &c2) != 4) return;
  want_image = image != 0;
  want_colors = colors != 0;
  want_c1 = c1 & 0xffffffu;
  want_c2 = c2 & 0xffffffu;
}

bool WyrmCustomTagSetImage(const uint8_t* png, size_t length) {
  static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a};
  if (!png || length < sizeof(signature) || length > MAX_IMAGE_BYTES) return false;
  if (memcmp(png, signature, sizeof(signature)) != 0) return false;
  if (!SDL_SaveFile(CUSTOM_IMAGE, png, length)) return false;
  pending = true;
  return true;
}

void WyrmCustomTagConfigure(bool use_image, bool use_colors, uint32_t c1,
                            uint32_t c2) {
  loaded = true; /* the caller's values win over the saved ones */
  want_image = use_image;
  want_colors = use_colors;
  want_c1 = c1 & 0xffffffu;
  want_c2 = c2 & 0xffffffu;
  if (use_image && !image_tex) pending = true;
  config_dirty = true;
  dirty_frames = 0;
}

void WyrmCustomTagApply(tenv* env) {
  if (!env || !env->usr || !env->usr->r || !env->ctx) return;
  renderer* r = env->usr->r;
  if (!r->tags_descriptor) return; /* the renderer is not up yet */

  if (!loaded) {
    loaded = true;
    config_load();
    if (want_image) pending = true;
  }
  if (config_dirty && ++dirty_frames >= 30) config_save();

  if (!pending) return;
  pending = false;
  if (!SDL_GetPathInfo(CUSTOM_IMAGE, NULL)) {
    want_image = false; /* nothing to draw from */
    return;
  }
  texture* fresh = create_mipmap_texture(env->ctx, CUSTOM_IMAGE);
  if (!fresh) return;
  VkDescriptorSet descriptor = igImplVulkan_AddTexture(
      r->linear_sampler, fresh->view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
  texture* old_tex = image_tex;
  VkDescriptorSet old_descriptor = image_descriptor;
  image_tex = fresh;
  image_descriptor = descriptor;
  if (old_tex) {
    /* A picture change is rare and happens in the editor, so waiting for the
       GPU here is cheaper than tracking which frame last used the old one. */
    vkDeviceWaitIdle(env->ctx->device);
    igImplVulkan_RemoveTexture(old_descriptor);
    destroy_texture(env->ctx, old_tex);
  }
  SDL_Log("Wyrm custom tag picture ready %dx%d", fresh->size[0], fresh->size[1]);
}

bool wyrm_custom_tag_image_active(void) { return want_image && image_tex != NULL; }

const struct tag_entry* wyrm_custom_tag_entry(bool mine,
                                              const struct tag_entry* base,
                                              struct tag_entry* out) {
  drawing_custom = false;
  if (!mine || !out) return base;

  if (want_image && image_tex) {
    float tw = (float)image_tex->size[0];
    float th = (float)image_tex->size[1];
    float fit = BOX_LONG_SIDE / (tw > th ? tw : th);
    float w = tw * fit;
    float h = th * fit;
    if (w < 8.0f) w = 8.0f;
    if (h < 8.0f) h = 8.0f;
    memset(out, 0, sizeof(*out));
    out->w = (int)(w + 0.5f);
    out->h = (int)(h + 0.5f);
    out->bx = -(int)(w * BOX_ANCHOR_X + 0.5f);
    out->by = -(int)(h * 0.5f + 0.5f);
    out->c1 = want_colors ? want_c1 : 0x555555u;
    out->c2 = want_colors ? want_c2 : 0xaaaaaau;
    out->ntl = -1;
    out->uv[0] = 0.0f;
    out->uv[1] = 0.0f;
    out->uv[2] = 1.0f;
    out->uv[3] = 1.0f;
    drawing_custom = true;
    return out;
  }
  if (base && want_colors) {
    *out = *base;
    out->c1 = want_c1;
    out->c2 = want_c2;
    return out;
  }
  return base;
}

bool wyrm_custom_tag_drawing(void) { return drawing_custom; }

uintptr_t wyrm_custom_tag_descriptor(void) { return (uintptr_t)image_descriptor; }
