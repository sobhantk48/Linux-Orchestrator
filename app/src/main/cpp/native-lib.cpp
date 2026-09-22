#include <jni.h>
#include <string>
#include <android/log.h>

#define TAG "LinuxOrchestratorNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

extern "C" JNIEXPORT jstring JNICALL
Java_com_linuxorchestrator_app_MainActivity_stringFromJNI(
    JNIEnv* env,
    jobject /* this */) {
    std::string hello = "Linux Orchestrator Native Core v0.1.0 Ready";
    return env->NewStringUTF(hello.c_str());
}
