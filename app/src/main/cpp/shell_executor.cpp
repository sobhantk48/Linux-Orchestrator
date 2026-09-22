#include "shell_executor.h"
#include <array>
#include <memory>
#include <cstdio>
#include <sys/wait.h>

namespace orchestrator {

CommandResult ShellExecutor::executeCommand(const std::string& command) {
    CommandResult result{-1, "", ""};
    std::array<char, 256> buffer;

    // هدایت stderr به stdout برای دریافت لاگ‌های خطای شل
    std::string fullCmd = command + " 2>&1";
    FILE* pipe = popen(fullCmd.c_str(), "r");
    if (!pipe) {
        result.error = "popen() failed!";
        return result;
    }

    while (fgets(buffer.data(), buffer.size(), pipe) != nullptr) {
        result.output += buffer.data();
    }

    int status = pclose(pipe);
    if (WIFEXITED(status)) {
        result.exitCode = WEXITSTATUS(status);
    } else {
        result.exitCode = -1;
    }

    return result;
}

int ShellExecutor::executeStreaming(const std::string& command,
                                    const std::function<void(const std::string&)>& onOutput) {
    std::array<char, 256> buffer;
    std::string fullCmd = command + " 2>&1";
    FILE* pipe = popen(fullCmd.c_str(), "r");
    if (!pipe) {
        return -1;
    }

    while (fgets(buffer.data(), buffer.size(), pipe) != nullptr) {
        if (onOutput) {
            onOutput(std::string(buffer.data()));
        }
    }

    int status = pclose(pipe);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

} // namespace orchestrator
