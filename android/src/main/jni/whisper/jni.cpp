#include <jni.h>
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <android/log.h>
#include <cstdlib>
#include <sys/sysinfo.h>
#include <string>
#include "whisper.h"
#include "rn-whisper.h"
#include "ggml.h"

#define UNUSED(x) (void)(x)
#define TAG "JNI"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,     TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,     TAG, __VA_ARGS__)

static inline int min(int a, int b) {
    return (a < b) ? a : b;
}

static inline int max(int a, int b) {
    return (a > b) ? a : b;
}

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_rnwhisper_WhisperContext_initContext(
        JNIEnv *env, jobject thiz, jstring model_path_str) {
    UNUSED(thiz);
    struct whisper_context *context = nullptr;
    const char *model_path_chars = env->GetStringUTFChars(model_path_str, nullptr);
    context = whisper_init_from_file(model_path_chars);
    env->ReleaseStringUTFChars(model_path_str, model_path_chars);
    return reinterpret_cast<jlong>(context);
}

JNIEXPORT jint JNICALL
Java_com_rnwhisper_WhisperContext_fullTranscribe(
    JNIEnv *env,
    jobject thiz,
    jlong context_ptr,
    jfloatArray audio_data,
    jint n_threads,
    jint max_context,
    jint max_len,
    jint offset,
    jint duration,
    jint word_thold,
    jfloat temperature,
    jfloat temperature_inc,
    jint beam_size,
    jint best_of,
    jboolean speed_up,
    jboolean translate,
    jstring language,
    jstring prompt
) {
    UNUSED(thiz);
    struct whisper_context *context = reinterpret_cast<struct whisper_context *>(context_ptr);
    jfloat *audio_data_arr = env->GetFloatArrayElements(audio_data, nullptr);
    const jsize audio_data_length = env->GetArrayLength(audio_data);

    int max_threads = max(1, min(8, get_nprocs() - 2));

    LOGI("About to create params");

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

    if (beam_size > -1) {
        params.strategy = WHISPER_SAMPLING_BEAM_SEARCH;
        params.beam_search.beam_size = beam_size;
    }

    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = translate;
    const char *language_chars = env->GetStringUTFChars(language, nullptr);
    params.language = language_chars;
    params.n_threads = n_threads > 0 ? n_threads : max_threads;
    params.speed_up = speed_up;
    params.offset_ms = 0;
    params.no_context = true;
    params.single_segment = false;

    if (best_of > -1) {
        params.greedy.best_of = best_of;
    }
    if (max_context > -1) {
        params.n_max_text_ctx = max_context;
    }
    if (max_len > -1) {
        params.max_len = max_len;
    }
    if (offset > -1) {
        params.offset_ms = offset;
    }
    if (duration > -1) {
        params.duration_ms = duration;
    }
    if (word_thold > -1) {
        params.thold_pt = word_thold;
    }
    if (temperature > -1) {
        params.temperature = temperature;
    }
    if (temperature_inc > -1) {
        params.temperature_inc = temperature_inc;
    }
    if (prompt != nullptr) {
        rn_whisper_convert_prompt(
            context,
            params,
            new std::string(env->GetStringUTFChars(prompt, nullptr))
        );
    }

    LOGI("About to reset timings");
    whisper_reset_timings(context);

    LOGI("About to run whisper_full");
    int code = whisper_full(context, params, audio_data_arr, audio_data_length);
    if (code == 0) {
        // whisper_print_timings(context);
    }
    env->ReleaseFloatArrayElements(audio_data, audio_data_arr, JNI_ABORT);
    env->ReleaseStringUTFChars(language, language_chars);
    return code;
}

JNIEXPORT jint JNICALL
Java_com_rnwhisper_WhisperContext_getTextSegmentCount(
        JNIEnv *env, jobject thiz, jlong context_ptr) {
    UNUSED(env);
    UNUSED(thiz);
    struct whisper_context *context = reinterpret_cast<struct whisper_context *>(context_ptr);
    return whisper_full_n_segments(context);
}

JNIEXPORT jstring JNICALL
Java_com_rnwhisper_WhisperContext_getTextSegment(
        JNIEnv *env, jobject thiz, jlong context_ptr, jint index) {
    UNUSED(thiz);
    struct whisper_context *context = reinterpret_cast<struct whisper_context *>(context_ptr);
    const char *text = whisper_full_get_segment_text(context, index);
    jstring string = env->NewStringUTF(text);
    return string;
}

JNIEXPORT void JNICALL
Java_com_rnwhisper_WhisperContext_freeContext(
        JNIEnv *env, jobject thiz, jlong context_ptr) {
    UNUSED(env);
    UNUSED(thiz);
    struct whisper_context *context = reinterpret_cast<struct whisper_context *>(context_ptr);
    whisper_free(context);
}

} // extern "C"