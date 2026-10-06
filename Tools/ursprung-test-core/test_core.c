// SPDX-License-Identifier: GPL-3.0-or-later
// Ursprung — a libretro core for tests. Its state is the number of frames it
// has run; tests switch failures on through the ur_test_core_* functions.

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "libretro.h"

static retro_video_refresh_t video;
static retro_input_poll_t inputPoll;
static uint32_t frame;
static bool unserializeFails;
static uint32_t pixels[4 * 4];

RETRO_API void ur_test_core_set_unserialize_fails(bool fails) { unserializeFails = fails; }
RETRO_API uint32_t ur_test_core_frame(void) { return frame; }

RETRO_API unsigned retro_api_version(void) { return RETRO_API_VERSION; }

RETRO_API void retro_get_system_info(struct retro_system_info *info) {
    memset(info, 0, sizeof(*info));
    info->library_name = "Ursprung Test Core";
    info->library_version = "1";
    info->valid_extensions = "bin";
    info->need_fullpath = true;
}

RETRO_API void retro_get_system_av_info(struct retro_system_av_info *info) {
    memset(info, 0, sizeof(*info));
    info->geometry.base_width = info->geometry.max_width = 4;
    info->geometry.base_height = info->geometry.max_height = 4;
    info->geometry.aspect_ratio = 1;
    info->timing.fps = 60;
    info->timing.sample_rate = 48000;
}

RETRO_API void retro_set_environment(retro_environment_t callback) {
    enum retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
    callback(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);
}

RETRO_API void retro_set_video_refresh(retro_video_refresh_t callback) { video = callback; }
RETRO_API void retro_set_audio_sample(retro_audio_sample_t callback) { (void)callback; }
RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t callback) { (void)callback; }
RETRO_API void retro_set_input_poll(retro_input_poll_t callback) { inputPoll = callback; }
RETRO_API void retro_set_input_state(retro_input_state_t callback) { (void)callback; }
RETRO_API void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }

RETRO_API void retro_init(void) { frame = 0; unserializeFails = false; }
RETRO_API void retro_deinit(void) {}
RETRO_API void retro_reset(void) { frame = 0; }

RETRO_API void retro_run(void) {
    if (inputPoll) inputPoll();
    frame++;
    if (video) video(pixels, 4, 4, 4 * sizeof(uint32_t));
}

RETRO_API size_t retro_serialize_size(void) { return sizeof(frame); }

RETRO_API bool retro_serialize(void *data, size_t size) {
    if (size < sizeof(frame)) return false;
    memcpy(data, &frame, sizeof(frame));
    return true;
}

RETRO_API bool retro_unserialize(const void *data, size_t size) {
    if (unserializeFails || size < sizeof(frame)) return false;
    memcpy(&frame, data, sizeof(frame));
    return true;
}

RETRO_API bool retro_load_game(const struct retro_game_info *game) { (void)game; return true; }
RETRO_API void retro_unload_game(void) {}
RETRO_API void *retro_get_memory_data(unsigned id) { (void)id; return NULL; }
RETRO_API size_t retro_get_memory_size(unsigned id) { (void)id; return 0; }
