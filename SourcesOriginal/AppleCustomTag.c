#include "WyrmCustomTag.h"
#include "WyrmCustomTagBridge.h"

#include <SDL3/SDL.h>
#include <external/stb/stb_image.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "game/tag_table.h"
#include "rendering/renderer.h"
#include "user.h"

#define IMAGE_NAME "custom_tag.png"
#define CONFIG_NAME "custom_tag.cfg"
#define MAX_IMAGE_BYTES (4u * 1024u * 1024u)
#define MAX_IMAGE_SIDE 1024
/* The longer side of a custom picture's box, in the table's units: Wyrm's own
   boxes are about 170 to 180 across, so a picture of any resolution hangs at
   the size its neighbours do. */
#define BOX_LONG_SIDE 170.0f
/* Where Wyrm's own boxes hang: 17 % of their width back from the rope's end. */
#define BOX_ANCHOR_X 0.17f

static bool want_image;
static bool want_colors;
static uint32_t want_c1 = 0xffdaf5;
static uint32_t want_c2 = 0x8562d0;
static float want_scale = 1.0f;
static float want_along = 0.0f;
static float want_across = 0.0f;
static bool loaded;
static bool pending;
static bool config_dirty;
static unsigned dirty_frames;

static texture* image_tex;
static VkDescriptorSet image_descriptor;
static tag_entry picture_entry;
static tag_entry adjusted_entry;

static int status_code;
static char status_text[160] = "no picture yet";

static char folder[1024];
static bool folder_ready;

static void status_set(int code, const char* format, ...) {
  va_list args;
  va_start(args, format);
  vsnprintf(status_text, sizeof(status_text), format, args);
  va_end(args);
  status_code = code;
  SDL_Log("Wyrm custom tag: %s", status_text);
}

/* Where the picture and the setting live: a folder of their own, by absolute
   path, so neither the engine's working directory nor a new build's fresh copy
   of its resources can touch them. */
static const char* path_to(const char* name, char* out, size_t capacity) {
  if (!folder_ready) {
    folder_ready = true;
    char* pref = SDL_GetPrefPath("Wyrm", "CustomTag");
    if (pref) {
      snprintf(folder, sizeof(folder), "%s", pref);
      SDL_free(pref);
    }
  }
  snprintf(out, capacity, "%s%s", folder, name);
  return out;
}

static float clampf(float v, float lo, float hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

static void config_save(void) {
  char path[1200];
  char line[160];
  int n = snprintf(line, sizeof(line), "%d %d %u %u %.4f %.4f %.4f\n",
                   want_image ? 1 : 0, want_colors ? 1 : 0, (unsigned)want_c1,
                   (unsigned)want_c2, (double)want_scale, (double)want_along,
                   (double)want_across);
  if (n > 0 && SDL_SaveFile(path_to(CONFIG_NAME, path, sizeof(path)), line,
                            (size_t)n))
    config_dirty = false;
}

static void config_load(void) {
  char path[1200];
  size_t size = 0;
  void* data = SDL_LoadFile(path_to(CONFIG_NAME, path, sizeof(path)), &size);
  if (!data) return;
  char line[160] = {0};
  memcpy(line, data, size < sizeof(line) - 1 ? size : sizeof(line) - 1);
  SDL_free(data);
  int image = 0, colors = 0;
  unsigned c1 = 0, c2 = 0;
  float scale = 1.0f, along = 0.0f, across = 0.0f;
  int got = sscanf(line, "%d %d %u %u %f %f %f", &image, &colors, &c1, &c2,
                   &scale, &along, &across);
  if (got < 4) return; /* an older setting has no size or position */
  want_image = image != 0;
  want_colors = colors != 0;
  want_c1 = c1 & 0xffffffu;
  want_c2 = c2 & 0xffffffu;
  if (got >= 7) {
    want_scale = clampf(scale, 0.1f, 4.0f);
    want_along = clampf(along, -2.0f, 2.0f);
    want_across = clampf(across, -2.0f, 2.0f);
  }
}

bool WyrmCustomTagSetImage(const uint8_t* png, size_t length) {
  static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a};
  if (!png || length < sizeof(signature) || length > MAX_IMAGE_BYTES) {
    status_set(-1, "picture rejected: %zu bytes", length);
    return false;
  }
  if (memcmp(png, signature, sizeof(signature)) != 0) {
    status_set(-1, "picture rejected: not a PNG");
    return false;
  }
  /* Decoded here as well, so a picture the engine's decoder cannot read is
     reported now rather than drawn as the loader's fallback pattern. */
  int w = 0, h = 0, c = 0;
  if (!stbi_info_from_memory(png, (int)length, &w, &h, &c) || w <= 0 || h <= 0 ||
      w > MAX_IMAGE_SIDE || h > MAX_IMAGE_SIDE) {
    status_set(-1, "picture rejected: %s", stbi_failure_reason());
    return false;
  }
  char path[1200];
  path_to(IMAGE_NAME, path, sizeof(path));
  if (!SDL_SaveFile(path, png, length)) {
    status_set(-1, "picture could not be saved: %s", SDL_GetError());
    return false;
  }
  pending = true;
  status_set(0, "picture saved %dx%d, waiting for the engine", w, h);
  return true;
}

void WyrmCustomTagConfigure(bool use_image, bool use_colors, uint32_t c1,
                            uint32_t c2, float scale, float along,
                            float across) {
  loaded = true; /* the caller's values win over the saved ones */
  want_image = use_image;
  want_colors = use_colors;
  want_c1 = c1 & 0xffffffu;
  want_c2 = c2 & 0xffffffu;
  want_scale = clampf(scale, 0.1f, 4.0f);
  want_along = clampf(along, -2.0f, 2.0f);
  want_across = clampf(across, -2.0f, 2.0f);
  if (use_image && !image_tex) pending = true;
  config_dirty = true;
  dirty_frames = 0;
}

int WyrmCustomTagStatus(char* text, size_t capacity) {
  if (text && capacity > 0) snprintf(text, capacity, "%s", status_text);
  return status_code;
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

  char path[1200];
  path_to(IMAGE_NAME, path, sizeof(path));
  int w = 0, h = 0, c = 0;
  if (!stbi_info(path, &w, &h, &c) || w <= 0 || h <= 0 || w > MAX_IMAGE_SIDE ||
      h > MAX_IMAGE_SIDE) {
    status_set(-1, "cannot read the saved picture: %s", stbi_failure_reason());
    return;
  }
  texture* fresh = create_mipmap_texture(env->ctx, path);
  if (!fresh) {
    status_set(-1, "the engine could not make a texture");
    return;
  }
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
  status_set(1, "ready %dx%d", fresh->size[0], fresh->size[1]);
}

bool wyrm_custom_tag_image_active(void) { return want_image && image_tex != NULL; }

static bool adjusted(void) {
  return fabsf(want_scale - 1.0f) > 0.001f || fabsf(want_along) > 0.001f ||
         fabsf(want_across) > 0.001f;
}

const struct tag_entry* wyrm_custom_tag_entry(bool mine,
                                              const struct tag_entry* base) {
  if (!mine) return base;

  if (want_image && image_tex) {
    float tw = (float)image_tex->size[0];
    float th = (float)image_tex->size[1];
    float fit = BOX_LONG_SIDE / (tw > th ? tw : th);
    float w = tw * fit * want_scale;
    float h = th * fit * want_scale;
    if (w < 4.0f) w = 4.0f;
    if (h < 4.0f) h = 4.0f;
    memset(&picture_entry, 0, sizeof(picture_entry));
    picture_entry.w = (int)(w + 0.5f);
    picture_entry.h = (int)(h + 0.5f);
    picture_entry.bx = (int)lroundf(-w * BOX_ANCHOR_X + want_along * w);
    picture_entry.by = (int)lroundf(-h * 0.5f + want_across * h);
    picture_entry.c1 = want_colors ? want_c1 : 0x555555u;
    picture_entry.c2 = want_colors ? want_c2 : 0xaaaaaau;
    picture_entry.ntl = -1;
    picture_entry.uv[0] = 0.0f;
    picture_entry.uv[1] = 0.0f;
    picture_entry.uv[2] = 1.0f;
    picture_entry.uv[3] = 1.0f;
    return &picture_entry;
  }
  if (base && (want_colors || adjusted())) {
    adjusted_entry = *base;
    if (want_colors) {
      adjusted_entry.c1 = want_c1;
      adjusted_entry.c2 = want_c2;
    }
    if (adjusted()) {
      float w = (float)base->w * want_scale;
      float h = (float)base->h * want_scale;
      adjusted_entry.w = (int)(w + 0.5f);
      adjusted_entry.h = (int)(h + 0.5f);
      adjusted_entry.bx = (int)lroundf((float)base->bx * want_scale + want_along * w);
      adjusted_entry.by = (int)lroundf((float)base->by * want_scale + want_across * h);
    }
    return &adjusted_entry;
  }
  return base;
}

uintptr_t wyrm_custom_tag_descriptor_for(const struct tag_entry* tag,
                                         uintptr_t fallback) {
  return tag == &picture_entry && image_tex ? (uintptr_t)image_descriptor : fallback;
}
