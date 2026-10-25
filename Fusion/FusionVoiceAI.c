#include "FusionAIVoice.h"
#ifndef FUSION_AI_VOICE
#define FUSION_AI_VOICE 0
#endif
#if FUSION_AI_VOICE
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
static pthread_mutex_t segment_mutex=PTHREAD_MUTEX_INITIALIZER;
typedef struct {const uint8_t *bytes;size_t size,pos;} AIReader;
static int ai_read(void *opaque,uint8_t *b,int n){AIReader *r=opaque;size_t count=r->size-r->pos;if(!count)return AVERROR_EOF;if(count>(size_t)n)count=n;memcpy(b,r->bytes+r->pos,count);r->pos+=count;return (int)count;}
static int64_t ai_seek(void *opaque,int64_t p,int whence){AIReader*r=opaque;if(whence==AVSEEK_SIZE)return r->size;int64_t next=(whence==SEEK_SET?p:whence==SEEK_CUR?(int64_t)r->pos+p:(int64_t)r->size+p);if(next<0||(uint64_t)next>r->size)return AVERROR(EINVAL);r->pos=next;return next;}
static int ai_packets(AVFormatContext *out,AVCodecContext *enc,AVPacket *p,int stream,int64_t first){int status;while((status=avcodec_receive_packet(enc,p))>=0){if(p->pts<first){av_packet_unref(p);continue;}p->stream_index=stream;av_packet_rescale_ts(p,enc->time_base,out->streams[stream]->time_base);int result=av_interleaved_write_frame(out,p);av_packet_unref(p);if(result<0)return result;}return status==AVERROR(EAGAIN)||status==AVERROR_EOF?0:status;}
/* Decode once, model in source-aligned PCM, encode AAC only. Video packets copy.
 * Atomic failure: caller keeps the complete unmodified upstream segment. */
int fusion_ai_segment(const uint8_t*input,size_t length,float strength,uint8_t**output,size_t*output_length){
 if(!output||!output_length)return -1;*output=NULL;*output_length=0;if(!input||length<32||length>24*1024*1024||!isfinite(strength)||strength<=0)return 0;
 pthread_mutex_lock(&segment_mutex);
 AVFormatContext *in=NULL,*out=NULL;AVIOContext *io=NULL;AVCodecContext *dec=NULL,*enc=NULL;AVPacket *p=NULL,*encoded=NULL;AVFrame *frame=NULL,**frames=NULL;uint8_t *buffer=NULL,*result=NULL;float *pcm[2]={0};
 int result_size=0,answer=-1,audio=-1,dest=-1,mapping[32],frame_count=0,capacity=0;size_t sample_count=0;int64_t first_pts=AV_NOPTS_VALUE;
 AIReader reader={input,length,0};memset(mapping,-1,sizeof(mapping));
 in=avformat_alloc_context();buffer=av_malloc(32768);if(!in||!buffer)goto done;io=avio_alloc_context(buffer,32768,0,&reader,ai_read,NULL,ai_seek);if(!io)goto done;buffer=NULL;in->pb=io;in->flags|=AVFMT_FLAG_CUSTOM_IO;in->probesize=1024*1024;in->max_analyze_duration=2*AV_TIME_BASE;
 if(avformat_open_input(&in,NULL,NULL,NULL)<0||avformat_find_stream_info(in,NULL)<0||in->nb_streams>32)goto done;
 audio=av_find_best_stream(in,AVMEDIA_TYPE_AUDIO,-1,-1,NULL,0);if(audio<0){answer=0;goto done;}AVCodecParameters *par=in->streams[audio]->codecpar;
 if(par->codec_id!=AV_CODEC_ID_AAC||par->ch_layout.nb_channels<1||par->ch_layout.nb_channels>2){answer=0;goto done;}
 dec=avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_AAC));enc=avcodec_alloc_context3(avcodec_find_encoder(AV_CODEC_ID_AAC));if(!dec||!enc)goto done;
 if(avcodec_parameters_to_context(dec,par)<0||avcodec_open2(dec,dec->codec,NULL)<0)goto done;
 if(dec->sample_fmt!=AV_SAMPLE_FMT_FLTP||dec->sample_rate<16000||dec->sample_rate>96000){answer=0;goto done;}
 enc->sample_rate=dec->sample_rate;enc->sample_fmt=AV_SAMPLE_FMT_FLTP;enc->time_base=(AVRational){1,dec->sample_rate};enc->bit_rate=192000;av_channel_layout_default(&enc->ch_layout,dec->ch_layout.nb_channels);if(avcodec_open2(enc,enc->codec,NULL)<0)goto done;
 if(avformat_alloc_output_context2(&out,NULL,"mpegts",NULL)<0)goto done;
 out->max_interleave_delta=30*AV_TIME_BASE; /* Bound <=24s while preserving cross-stream order. */
 for(unsigned i=0;i<in->nb_streams;i++){AVCodecParameters *cp=in->streams[i]->codecpar;if((int)i!=audio&&cp->codec_type!=AVMEDIA_TYPE_VIDEO)continue;AVStream *s=avformat_new_stream(out,NULL);if(!s)goto done;mapping[i]=s->index;s->time_base=in->streams[i]->time_base;
  if((int)i==audio){dest=s->index;if(avcodec_parameters_from_context(s->codecpar,enc)<0)goto done;}else if(avcodec_parameters_copy(s->codecpar,cp)<0)goto done;s->codecpar->codec_tag=0;}
 if(avio_open_dyn_buf(&out->pb)<0)goto done;AVDictionary *opts=NULL;av_dict_set(&opts,"mpegts_copyts","1",0);av_dict_set(&opts,"mpegts_flags","resend_headers",0);av_opt_set_double(out,"muxdelay",0,0);int header=avformat_write_header(out,&opts);av_dict_free(&opts);if(header<0)goto done;
 p=av_packet_alloc();encoded=av_packet_alloc();frame=av_frame_alloc();if(!p||!encoded||!frame)goto done;
 while(av_read_frame(in,p)>=0){int index=p->stream_index;
  if(index==audio){if(avcodec_send_packet(dec,p)<0)goto done;av_packet_unref(p);
   while(avcodec_receive_frame(dec,frame)>=0){if(frame->format!=AV_SAMPLE_FMT_FLTP||frame->ch_layout.nb_channels!=dec->ch_layout.nb_channels||frame->nb_samples!=enc->frame_size||frame->best_effort_timestamp==AV_NOPTS_VALUE)goto done;
    if(sample_count+(size_t)frame->nb_samples>(size_t)dec->sample_rate*24){answer=-4;goto done;}
    if(frame_count==capacity){int next=capacity?capacity*2:64;AVFrame **allocation=realloc(frames,sizeof(*frames)*next);if(!allocation)goto done;frames=allocation;capacity=next;}
    frames[frame_count]=av_frame_clone(frame);if(!frames[frame_count])goto done;frame_count++;sample_count+=frame->nb_samples;av_frame_unref(frame);}
  }else if(index>=0&&index<32&&mapping[index]>=0){p->stream_index=mapping[index];av_packet_rescale_ts(p,in->streams[index]->time_base,out->streams[p->stream_index]->time_base);if(av_interleaved_write_frame(out,p)<0)goto done;av_packet_unref(p);}else av_packet_unref(p);
  if(out->pb->pos>32*1024*1024)goto done;
 }
 if(!frame_count)goto done;
 for(int c=0;c<dec->ch_layout.nb_channels;c++){pcm[c]=calloc(sample_count,sizeof(float));if(!pcm[c])goto done;size_t at=0;for(int j=0;j<frame_count;j++){memcpy(pcm[c]+at,frames[j]->extended_data[c],frames[j]->nb_samples*sizeof(float));at+=frames[j]->nb_samples;}}
 answer=fusion_ai_pcm(pcm,sample_count,dec->sample_rate,dec->ch_layout.nb_channels,strength);if(answer!=1)goto done;
 for(int j=0,offset=0;j<frame_count;j++){AVFrame *f=frames[j];if(av_frame_make_writable(f)<0){answer=-1;goto done;}
  for(int c=0;c<dec->ch_layout.nb_channels;c++)memcpy(f->extended_data[c],pcm[c]+offset,f->nb_samples*sizeof(float));offset+=f->nb_samples;
  f->pts=av_rescale_q(f->best_effort_timestamp,in->streams[audio]->time_base,enc->time_base);if(first_pts==AV_NOPTS_VALUE)first_pts=f->pts;
  if(avcodec_send_frame(enc,f)<0||ai_packets(out,enc,encoded,dest,first_pts)<0){answer=-1;goto done;}}
 if(avcodec_send_frame(enc,NULL)<0||ai_packets(out,enc,encoded,dest,first_pts)<0||av_write_trailer(out)<0){answer=-1;goto done;}
 result_size=avio_close_dyn_buf(out->pb,&result);out->pb=NULL;if(result_size<=0||result_size>32*1024*1024){answer=-1;goto done;}*output=result;*output_length=result_size;result=NULL;answer=1;
done:
 av_free(result);for(int c=0;c<2;c++)free(pcm[c]);for(int j=0;j<frame_count;j++)av_frame_free(&frames[j]);free(frames);
 av_packet_free(&p);av_packet_free(&encoded);av_frame_free(&frame);avcodec_free_context(&dec);avcodec_free_context(&enc);
 if(out){if(out->pb){uint8_t *discard=NULL;avio_close_dyn_buf(out->pb,&discard);av_free(discard);}avformat_free_context(out);}
 if(in)avformat_close_input(&in);if(io){av_freep(&io->buffer);avio_context_free(&io);}av_free(buffer);pthread_mutex_unlock(&segment_mutex);return answer;
}
#else
int fusion_ai_segment(const uint8_t *input,size_t length,float strength,uint8_t **output,size_t *output_length){(void)input;(void)length;(void)strength;if(output)*output=NULL;if(output_length)*output_length=0;return 0;}
#endif
