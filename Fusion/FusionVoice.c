#include "FusionVoice.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <math.h>
#include <string.h>
typedef struct {const uint8_t *bytes;size_t size,pos;} Reader;
static int read_bytes(void *opaque,uint8_t *b,int n){Reader *r=opaque;size_t count=r->size-r->pos;if(!count)return AVERROR_EOF;if(count>(size_t)n)count=n;memcpy(b,r->bytes+r->pos,count);r->pos+=count;return (int)count;}
static int64_t seek_bytes(void *opaque,int64_t p,int whence){Reader*r=opaque;if(whence==AVSEEK_SIZE)return r->size;int64_t next=(whence==SEEK_SET?p:whence==SEEK_CUR?(int64_t)r->pos+p:(int64_t)r->size+p);if(next<0||(uint64_t)next>r->size)return AVERROR(EINVAL);r->pos=next;return next;}
typedef struct {double a,b,prev,high,low;float amount;} Filter;
static void filter(AVFrame *f,Filter *v){float *l=(float*)f->extended_data[0],*r=(float*)f->extended_data[1];for(int i=0;i<f->nb_samples;i++){double mid=(l[i]+r[i])*.5;v->high=v->a*(v->high+mid-v->prev);v->prev=mid;v->low=v->b*v->low+(1-v->b)*v->high;double remove=v->amount*v->low;l[i]=fmax(-1,fmin(1,l[i]-remove));r[i]=fmax(-1,fmin(1,r[i]-remove));}}
static int packets(AVFormatContext *out,AVCodecContext *enc,AVPacket *p,int stream,int64_t first_pts){int status;while((status=avcodec_receive_packet(enc,p))>=0){if(p->pts<first_pts){av_packet_unref(p);continue;}p->stream_index=stream;av_packet_rescale_ts(p,enc->time_base,out->streams[stream]->time_base);int result=av_interleaved_write_frame(out,p);av_packet_unref(p);if(result<0)return result;}return status==AVERROR(EAGAIN)||status==AVERROR_EOF?0:status;}
int fusion_voice_segment(const uint8_t*input,size_t length,float strength,uint8_t**output,size_t*output_length){
 if(!output||!output_length)return -1;*output=NULL;*output_length=0;if(!input||length<32||length>24*1024*1024||!isfinite(strength)||strength<=0)return 0;
 AVFormatContext *in=NULL,*out=NULL;AVIOContext *io=NULL;AVCodecContext *dec=NULL,*enc=NULL;AVPacket *p=NULL,*encoded=NULL;AVFrame *frame=NULL;uint8_t *buffer=NULL,*result=NULL;int result_size=0,answer=-1,audio=-1,dest=-1,mapping[32],written=0;int64_t first_pts=AV_NOPTS_VALUE;
 Reader reader={input,length,0};memset(mapping,-1,sizeof(mapping));
 in=avformat_alloc_context();buffer=av_malloc(32768);if(!in||!buffer)goto done;io=avio_alloc_context(buffer,32768,0,&reader,read_bytes,NULL,seek_bytes);if(!io)goto done;buffer=NULL;in->pb=io;in->flags|=AVFMT_FLAG_CUSTOM_IO;in->probesize=1024*1024;in->max_analyze_duration=2*AV_TIME_BASE;
 if(avformat_open_input(&in,NULL,NULL,NULL)<0||avformat_find_stream_info(in,NULL)<0||in->nb_streams>32)goto done;
 audio=av_find_best_stream(in,AVMEDIA_TYPE_AUDIO,-1,-1,NULL,0);if(audio<0){answer=0;goto done;}AVCodecParameters *par=in->streams[audio]->codecpar;
 if(par->codec_id!=AV_CODEC_ID_AAC||par->ch_layout.nb_channels!=2){answer=0;goto done;}
 dec=avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_AAC));enc=avcodec_alloc_context3(avcodec_find_encoder(AV_CODEC_ID_AAC));if(!dec||!enc)goto done;
 if(avcodec_parameters_to_context(dec,par)<0||avcodec_open2(dec,dec->codec,NULL)<0)goto done;
 if(dec->sample_fmt!=AV_SAMPLE_FMT_FLTP||dec->sample_rate<8000||dec->sample_rate>96000){answer=0;goto done;}
 enc->sample_rate=dec->sample_rate;enc->sample_fmt=AV_SAMPLE_FMT_FLTP;enc->time_base=(AVRational){1,dec->sample_rate};enc->bit_rate=192000;av_channel_layout_default(&enc->ch_layout,2);if(avcodec_open2(enc,enc->codec,NULL)<0)goto done;
 if(avformat_alloc_output_context2(&out,NULL,"mpegts",NULL)<0)goto done;
 for(unsigned i=0;i<in->nb_streams;i++){AVCodecParameters *cp=in->streams[i]->codecpar;if((int)i!=audio&&cp->codec_type!=AVMEDIA_TYPE_VIDEO)continue;AVStream *s=avformat_new_stream(out,NULL);if(!s)goto done;mapping[i]=s->index;s->time_base=in->streams[i]->time_base;
  if((int)i==audio){dest=s->index;if(avcodec_parameters_from_context(s->codecpar,enc)<0)goto done;}else if(avcodec_parameters_copy(s->codecpar,cp)<0)goto done;s->codecpar->codec_tag=0;}
 if(avio_open_dyn_buf(&out->pb)<0)goto done;AVDictionary *opts=NULL;av_dict_set(&opts,"mpegts_copyts","1",0);av_dict_set(&opts,"mpegts_flags","resend_headers",0);av_opt_set_double(out,"muxdelay",0,0);int header=avformat_write_header(out,&opts);av_dict_free(&opts);if(header<0)goto done;
 p=av_packet_alloc();encoded=av_packet_alloc();frame=av_frame_alloc();if(!p||!encoded||!frame)goto done;
 Filter v={exp(-2*M_PI*180/dec->sample_rate),exp(-2*M_PI*5500/dec->sample_rate),0,0,0,fmaxf(0,fminf(1,strength))};
 while(av_read_frame(in,p)>=0){int index=p->stream_index;
  if(index==audio){if(avcodec_send_packet(dec,p)<0)goto done;av_packet_unref(p);
   while(avcodec_receive_frame(dec,frame)>=0){if(frame->format!=AV_SAMPLE_FMT_FLTP||frame->ch_layout.nb_channels!=2||frame->nb_samples!=enc->frame_size)goto done;
    if(av_frame_make_writable(frame)<0)goto done;filter(frame,&v);int64_t pts=frame->best_effort_timestamp;if(pts==AV_NOPTS_VALUE)goto done;frame->pts=av_rescale_q(pts,in->streams[audio]->time_base,enc->time_base);if(first_pts==AV_NOPTS_VALUE)first_pts=frame->pts;
    if(avcodec_send_frame(enc,frame)<0||packets(out,enc,encoded,dest,first_pts)<0)goto done;av_frame_unref(frame);written++;}
  }else if(index>=0&&index<32&&mapping[index]>=0){p->stream_index=mapping[index];av_packet_rescale_ts(p,in->streams[index]->time_base,out->streams[p->stream_index]->time_base);if(av_interleaved_write_frame(out,p)<0)goto done;av_packet_unref(p);}else av_packet_unref(p);
  if(out->pb->pos>32*1024*1024)goto done;
 }
 if(!written)goto done;if(avcodec_send_frame(enc,NULL)<0||packets(out,enc,encoded,dest,first_pts)<0||av_write_trailer(out)<0)goto done;
 result_size=avio_close_dyn_buf(out->pb,&result);out->pb=NULL;if(result_size<=0||result_size>32*1024*1024)goto done;*output=result;*output_length=result_size;result=NULL;answer=1;
done:
 av_free(result);av_packet_free(&p);av_packet_free(&encoded);av_frame_free(&frame);avcodec_free_context(&dec);avcodec_free_context(&enc);
 if(out){if(out->pb){uint8_t *discard=NULL;avio_close_dyn_buf(out->pb,&discard);av_free(discard);}avformat_free_context(out);}
 if(in)avformat_close_input(&in);if(io){av_freep(&io->buffer);avio_context_free(&io);}av_free(buffer);return answer;
}
void fusion_voice_free(void*data){av_free(data);}
/* Synthetic regression support: generated tones only; never a downloaded/user recording. */
int fusion_voice_fixture(int mono,uint8_t **output,size_t *length){
 AVFormatContext*out=NULL;AVCodecContext*enc=NULL;AVFrame*f=NULL;AVPacket*p=NULL;int ret=-1;
 if(!output||!length)return -1;*output=NULL;*length=0;
 enc=avcodec_alloc_context3(avcodec_find_encoder(AV_CODEC_ID_AAC));if(!enc)goto done;
 enc->sample_rate=48000;enc->sample_fmt=AV_SAMPLE_FMT_FLTP;enc->time_base=(AVRational){1,48000};enc->bit_rate=192000;av_channel_layout_default(&enc->ch_layout,mono?1:2);if(avcodec_open2(enc,enc->codec,NULL)<0)goto done;
 if(avformat_alloc_output_context2(&out,NULL,"mpegts",NULL)<0)goto done;AVStream*s=avformat_new_stream(out,NULL);if(!s||avcodec_parameters_from_context(s->codecpar,enc)<0||avio_open_dyn_buf(&out->pb)<0)goto done;
 s->time_base=enc->time_base;AVDictionary*opts=NULL;av_dict_set(&opts,"mpegts_copyts","1",0);int head=avformat_write_header(out,&opts);av_dict_free(&opts);if(head<0)goto done;
 f=av_frame_alloc();p=av_packet_alloc();if(!f||!p)goto done;f->format=enc->sample_fmt;f->sample_rate=48000;f->nb_samples=enc->frame_size;av_channel_layout_copy(&f->ch_layout,&enc->ch_layout);if(av_frame_get_buffer(f,0)<0)goto done;
 for(int j=0;j<190;j++){if(av_frame_make_writable(f)<0)goto done;f->pts=480000+j*f->nb_samples;
  for(int i=0;i<f->nb_samples;i++){double t=(j*f->nb_samples+i)/48000.;float centre=.2*sin(2*M_PI*1000*t),side=.1*sin(2*M_PI*300*t);((float*)f->data[0])[i]=centre+side;if(!mono)((float*)f->data[1])[i]=centre-side;}
  if(avcodec_send_frame(enc,f)<0||packets(out,enc,p,0,480000)<0)goto done;
 }
 if(avcodec_send_frame(enc,NULL)<0||packets(out,enc,p,0,480000)<0||av_write_trailer(out)<0)goto done;
 uint8_t*data=NULL;int size=avio_close_dyn_buf(out->pb,&data);out->pb=NULL;if(size<=0){av_free(data);goto done;}*output=data;*length=size;ret=1;
done:
 if(out){if(out->pb){uint8_t*discard=NULL;avio_close_dyn_buf(out->pb,&discard);av_free(discard);}avformat_free_context(out);}
 avcodec_free_context(&enc);av_frame_free(&f);av_packet_free(&p);return ret;
}
int fusion_voice_metrics(const uint8_t*data,size_t size,double *values){
 Reader r={data,size,0};AVFormatContext*in=avformat_alloc_context();AVIOContext*io=NULL;AVCodecContext*dec=NULL;AVPacket*p=NULL;AVFrame*f=NULL;uint8_t*b=av_malloc(32768);int ret=-1;double centre=0,side=0;int64_t samples=0,first=AV_NOPTS_VALUE,last=0;
 if(!in||!b||!values)goto done;io=avio_alloc_context(b,32768,0,&r,read_bytes,NULL,seek_bytes);if(!io)goto done;b=NULL;in->pb=io;in->flags|=AVFMT_FLAG_CUSTOM_IO;if(avformat_open_input(&in,NULL,NULL,NULL)<0||avformat_find_stream_info(in,NULL)<0)goto done;
 int a=av_find_best_stream(in,AVMEDIA_TYPE_AUDIO,-1,-1,NULL,0);if(a<0)goto done;dec=avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_AAC));if(!dec||avcodec_parameters_to_context(dec,in->streams[a]->codecpar)<0||avcodec_open2(dec,dec->codec,NULL)<0)goto done;
 p=av_packet_alloc();f=av_frame_alloc();if(!p||!f)goto done;
 while(av_read_frame(in,p)>=0){if(p->stream_index==a){if(avcodec_send_packet(dec,p)<0)goto done;while(avcodec_receive_frame(dec,f)>=0){if(f->format!=AV_SAMPLE_FMT_FLTP)goto done;int64_t pts=av_rescale_q(f->best_effort_timestamp,in->streams[a]->time_base,(AVRational){1,dec->sample_rate});if(first==AV_NOPTS_VALUE)first=pts;last=pts+f->nb_samples;
  float*l=(float*)f->data[0],*right=f->ch_layout.nb_channels==2?(float*)f->data[1]:l;
  for(int i=0;i<f->nb_samples;i++){if(samples>12000){double m=(l[i]+right[i])*.5,s=(l[i]-right[i])*.5;centre+=m*m;side+=s*s;}samples++;}av_frame_unref(f);}}av_packet_unref(p);}
 if(samples<=12000||first==AV_NOPTS_VALUE)goto done;values[0]=sqrt(centre/(samples-12000));values[1]=sqrt(side/(samples-12000));values[2]=(double)first/dec->sample_rate;values[3]=(double)(last-first)/dec->sample_rate;ret=1;
done:
 avcodec_free_context(&dec);av_packet_free(&p);av_frame_free(&f);if(in)avformat_close_input(&in);if(io){av_freep(&io->buffer);avio_context_free(&io);}av_free(b);return ret;
}

