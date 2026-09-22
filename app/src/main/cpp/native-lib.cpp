#include <jni.h>
#include <string>
#include "root_checker.h"
#include "shell_executor.h"

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_example_linuxorchestrator_core_NativeBridge_isDirectRoot(JNIEnv *env, jobject /* this */) {
    return static_cast<jboolean>(orchestrator::isRootAvailable());
}

JNIEXPORT jstring JNICALL
Java_com_example_linuxorchestrator_core_NativeBridge_getSELinuxMode(JNIEnv *env, jobject /* this */) {
    std::string status = orchestrator::getSELinuxStatus();
    return env->NewStringUTF(status.c_str());
}

JNIEXPORT jstring JNICALL
Java_com_example_linuxorchestrator_core_NativeBridge_runCommandNative(JNIEnv *env, jobject /* this */, jstring command) {
    const char *cmdCStr = env->GetStringUTFChars(command, nullptr);
    orchestrator::CommandResult result = orchestrator::ShellExecutor::executeCommand(cmdCStr);
    env->ReleaseStringUTFChars(command, cmdCStr);
    
    // برگرداندن خروجی استاندارد و خطا
    return env->NewStringUTF(result.output.c_str());
}

}
