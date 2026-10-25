#include "FusionAIVoice.h"
#ifndef FUSION_AI_VOICE
#define FUSION_AI_VOICE 0
#endif
#if FUSION_AI_VOICE
#include <onnxruntime_c_api.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <stdarg.h>
#define N 512
#define H 256
#define LEAD 4096 /* 256ms reflected warm-up per independent HLS segment. */
#define PI 3.14159265358979323846
static const OrtApi *api;
static OrtEnv *environment;
static OrtSession *session;
static OrtMemoryInfo *memory;
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static char detail[256]="AI model not initialized";
static unsigned long total_frames;
static pthread_mutex_t detail_mutex=PTHREAD_MUTEX_INITIALIZER;
static void set_detail(const char *format,...){pthread_mutex_lock(&detail_mutex);va_list args;va_start(args,format);vsnprintf(detail,sizeof(detail),format,args);va_end(args);pthread_mutex_unlock(&detail_mutex);}
static int failed(OrtStatus *s){if(!s)return 0;set_detail("AI error: %.190s; original audio retained",api->GetErrorMessage(s));api->ReleaseStatus(s);return 1;}
static double seconds(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
int fusion_ai_enabled(void){return 1;}
const char *fusion_ai_detail(void){static _Thread_local char copy[256];pthread_mutex_lock(&detail_mutex);memcpy(copy,detail,sizeof(copy));pthread_mutex_unlock(&detail_mutex);return copy;}
int fusion_ai_initialize(const char *path){
 pthread_mutex_lock(&mutex);if(session){pthread_mutex_unlock(&mutex);return 1;}
 api=OrtGetApiBase()->GetApi(ORT_API_VERSION);OrtSessionOptions *options=NULL;int ok=0;
 if(!api){set_detail("AI runtime API unavailable");goto done;}
 if(failed(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING,"FusionAI",&environment)))goto done;
 if(failed(api->DisableTelemetryEvents(environment))||failed(api->CreateSessionOptions(&options)))goto done;
 if(failed(api->SetIntraOpNumThreads(options,1))||failed(api->SetInterOpNumThreads(options,1))||failed(api->SetSessionExecutionMode(options,ORT_SEQUENTIAL))||failed(api->SetSessionGraphOptimizationLevel(options,ORT_ENABLE_ALL)))goto done;
 if(!path||failed(api->CreateSession(environment,path,options,&session)))goto done;
 if(failed(api->CreateCpuMemoryInfo(OrtArenaAllocator,OrtMemTypeDefault,&memory)))goto done;
 set_detail("GTCRN ready · local CPU, 1 thread");ok=1;
done:if(options)api->ReleaseSessionOptions(options);if(!ok){if(session)api->ReleaseSession(session);session=NULL;if(environment)api->ReleaseEnv(environment);environment=NULL;}pthread_mutex_unlock(&mutex);return ok;
}
/* Iterative radix-2 FFT: inverse includes 1/N, real bins are mirrored explicitly. */
static void fft(float *r,float *im,int inverse){
 for(int i=1,j=0;i<N;i++){int bit=N>>1;for(;j&bit;bit>>=1)j^=bit;j^=bit;if(i<j){float x=r[i];r[i]=r[j];r[j]=x;x=im[i];im[i]=im[j];im[j]=x;}}
 for(int size=2;size<=N;size<<=1){float angle=(inverse?2:-2)*PI/size,wr0=cosf(angle),wi0=sinf(angle);for(int start=0;start<N;start+=size){float wr=1,wi=0;for(int k=0;k<size/2;k++){int a=start+k,b=a+size/2;float tr=wr*r[b]-wi*im[b],ti=wr*im[b]+wi*r[b];r[b]=r[a]-tr;im[b]=im[a]-ti;r[a]+=tr;im[a]+=ti;float next=wr*wr0-wi*wi0;wi=wr*wi0+wi*wr0;wr=next;}}}
 if(inverse)for(int i=0;i<N;i++){r[i]/=N;im[i]/=N;}
}
static long reflected(long i,size_t count){if(count<=1)return 0;long n=(long)count;while(i<0||i>=n){if(i<0)i=-i;if(i>=n)i=2*n-2-i;}return i;}
typedef struct {OrtValue *mix,*state[3];float spectrum[514],conv[16896],tra[96],inter[1056];} Context;
static void release_context(Context *c){if(c->mix)api->ReleaseValue(c->mix);for(int i=0;i<3;i++)if(c->state[i])api->ReleaseValue(c->state[i]);}
static int create_tensor(float *data,size_t length,const int64_t *shape,size_t dims,OrtValue **out){return !failed(api->CreateTensorWithDataAsOrtValue(memory,data,length*sizeof(float),shape,dims,ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,out));}
static int initialize_context(Context *c){
 static const int64_t a[]={1,257,1,2},b[]={2,1,16,16,33},d[]={2,3,1,1,16},e[]={2,1,33,16};
 return create_tensor(c->spectrum,514,a,4,&c->mix)&&create_tensor(c->conv,16896,b,5,&c->state[0])&&create_tensor(c->tra,96,d,5,&c->state[1])&&create_tensor(c->inter,1056,e,4,&c->state[2]);
}
static int separate(const float *input,size_t count,float *speech,int bypass){
 size_t padded=count+LEAD+N;float *sum=calloc(padded,sizeof(float)),*norm=calloc(padded,sizeof(float));Context *c=calloc(1,sizeof(Context));int ok=0;
 if(!sum||!norm||!c)goto done;if(!bypass&&!initialize_context(c))goto done;
 float window[N];for(int i=0;i<N;i++)window[i]=sqrtf(.5f-.5f*cosf(2*PI*i/N));
 const char *names[]={"mix","conv_cache","tra_cache","inter_cache"},*outs[]={"enh","conv_cache_out","tra_cache_out","inter_cache_out"};
 for(size_t p=0;p+N<=padded;p+=H){
  float real[N],imag[N]={0};for(int i=0;i<N;i++)real[i]=input[reflected((long)p+i-LEAD,count)]*window[i];fft(real,imag,0);
  if(!bypass){for(int k=0;k<=N/2;k++){c->spectrum[k*2]=real[k];c->spectrum[k*2+1]=imag[k];}
   const OrtValue *inputs[]={c->mix,c->state[0],c->state[1],c->state[2]};OrtValue *values[4]={0};
   if(failed(api->Run(session,NULL,names,inputs,4,outs,4,values))){for(int i=0;i<4;i++)if(values[i])api->ReleaseValue(values[i]);goto done;}
   float *enh=NULL;if(failed(api->GetTensorMutableData(values[0],(void**)&enh))){for(int i=0;i<4;i++)api->ReleaseValue(values[i]);goto done;}
   for(int k=0;k<=N/2;k++){real[k]=enh[k*2];imag[k]=enh[k*2+1];}
   api->ReleaseValue(values[0]);for(int i=0;i<3;i++){api->ReleaseValue(c->state[i]);c->state[i]=values[i+1];}total_frames++;
  }
  imag[0]=imag[N/2]=0;for(int k=1;k<N/2;k++){real[N-k]=real[k];imag[N-k]=-imag[k];}fft(real,imag,1);
  for(int i=0;i<N;i++){sum[p+i]+=real[i]*window[i];norm[p+i]+=window[i]*window[i];}
 }
 for(size_t i=0;i<count;i++){speech[i]=sum[i+LEAD]/fmaxf(1e-9f,norm[i+LEAD]);if(!isfinite(speech[i]))goto done;}ok=1;
done:if(c){if(!bypass)release_context(c);free(c);}free(sum);free(norm);return ok;
}
int fusion_ai_reconstruct(const float *input,size_t frames,float *output){if(!input||!output||frames<2||frames>16000*30)return 0;return separate(input,frames,output,1);}
/* Windowed-sinc resampling with reflected ends. The native high-band is preserved:
 * only the aligned model speech estimate is upsampled and subtracted. */
static float *downsample(const float *input,size_t frames,int rate,size_t count){
 float *result=calloc(count,sizeof(float));if(!result)return NULL;float coeff[256][48];double cut=.45*fmin(1,16000./rate);
 for(int p=0;p<256;p++){double total=0;for(int k=0;k<48;k++){double x=k-23-p/256.,s=fabs(x)<1e-12?2*cut:sin(2*PI*cut*x)/(PI*x);double w=.5+.5*cos(PI*x/24);coeff[p][k]=s*w;total+=coeff[p][k];}for(int k=0;k<48;k++)coeff[p][k]/=total;}
 for(size_t i=0;i<count;i++){double at=i*(double)rate/16000;long start=(long)floor(at);int p=(int)((at-start)*256);double value=0;for(int k=0;k<48;k++)value+=input[reflected(start+k-23,frames)]*coeff[p][k];result[i]=(float)value;}return result;
}
int fusion_ai_pcm(float **channels,size_t frames,int rate,int channel_count,float amount){
 if(!channels||frames<2||rate<16000||rate>96000||channel_count<1||channel_count>2||frames>(size_t)rate*24||!isfinite(amount))return -4;
 for(int c=0;c<channel_count;c++)if(!channels[c])return -4;
 if(amount<=0)return 0;amount=fminf(1,amount);pthread_mutex_lock(&mutex);int ok=-2;double begin=seconds();
 if(!session){set_detail("AI model unavailable; original audio retained");goto done;}
 size_t count=(frames*16000+(size_t)rate-1)/(size_t)rate;float *voice[2]={0};
 for(int c=0;c<channel_count;c++){float *input=downsample(channels[c],frames,rate,count);voice[c]=calloc(count,sizeof(float));if(!input||!voice[c]){free(input);ok=-3;goto cleanup;}
  int worked=separate(input,count,voice[c],0);free(input);if(!worked){ok=-3;goto cleanup;}}
 for(int c=0;c<channel_count;c++)for(size_t i=0;i<frames;i++){double at=i*16000./rate;size_t a=(size_t)at,b=a+1<count?a+1:a;if(a>=count)a=b=count-1;double t=at-floor(at),speech=voice[c][a]*(1-t)+voice[c][b]*t;channels[c][i]=fmaxf(-1,fminf(1,channels[c][i]-amount*speech));}
 set_detail("GTCRN local CPU · %lu frames · RTF %.2f · %.0f%%",total_frames,(seconds()-begin)/(frames/(double)rate),amount*100);ok=1;
cleanup:for(int c=0;c<2;c++)free(voice[c]);
done:pthread_mutex_unlock(&mutex);return ok;
}
#else
int fusion_ai_enabled(void){return 0;}
int fusion_ai_initialize(const char *path){(void)path;return 0;}
const char *fusion_ai_detail(void){return "AI edition only";}
int fusion_ai_pcm(float **channels,size_t frames,int rate,int channel_count,float amount){(void)channels;(void)frames;(void)rate;(void)channel_count;(void)amount;return 0;}
int fusion_ai_reconstruct(const float *input,size_t frames,float *output){(void)input;(void)frames;(void)output;return 0;}
#endif
