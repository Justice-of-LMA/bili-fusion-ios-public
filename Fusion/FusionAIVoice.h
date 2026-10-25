#ifndef FUSION_AI_VOICE_H
#define FUSION_AI_VOICE_H
#include <stddef.h>
#include <stdint.h>
/* Normal builds compile inert stubs and do not link or ship ONNX Runtime/model. */
int fusion_ai_enabled(void);
int fusion_ai_initialize(const char *model_path);
const char *fusion_ai_detail(void);
/* Whole cached segment: original rate/channel/frame count remains unchanged. */
int fusion_ai_pcm(float **channels, size_t frames, int rate, int channel_count, float amount);
int fusion_ai_segment(const uint8_t *input,size_t length,float strength,uint8_t **output,size_t *output_length);
/* Synthetic test: bypass network math to check FFT/WOLA alignment only. */
int fusion_ai_reconstruct(const float *input,size_t frames,float *output);
#endif
