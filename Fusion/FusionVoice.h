#ifndef FUSION_VOICE_H
#define FUSION_VOICE_H
#include <stddef.h>
#include <stdint.h>
// 1=processed stereo AAC, 0=unsupported/bypass, negative=malformed input.
// Output is owned by caller; free through fusion_voice_free.
int fusion_voice_segment(const uint8_t *input,size_t length,float strength,uint8_t **output,size_t *output_length);
void fusion_voice_free(void *data);
int fusion_voice_fixture(int mono,uint8_t **output,size_t *length);
int fusion_voice_metrics(const uint8_t *input,size_t length,double *values);
#endif

