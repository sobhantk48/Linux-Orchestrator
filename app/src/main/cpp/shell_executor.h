#pragma once
#include <string>
#include <functional>

namespace orchestrator {

struct CommandResult {
    int exitCode;
    std::string output;
    std::string error;
};

class ShellExecutor {
public:
    static CommandResult executeCommand(const std::string& command);
    static int executeStreaming(const std::string& command, 
                                const std::function<void(const std::string&)>& onOutput);
};

} // namespace orchestrator
