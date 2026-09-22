#include "root_checker.h"
#include <unistd.h>
#include <sys/system_properties.h>
#include <fstream>
#include <sstream>

namespace orchestrator {

bool isRootAvailable() {
    // بررسی مستقیم UID کاربر فعلی
    return (getuid() == 0 || geteuid() == 0);
}

std::string getSELinuxStatus() {
    // 1. بررسی از مسیر فایل sysfs
    std::ifstream enforceFile("/sys/fs/selinux/enforce");
    if (enforceFile.is_open()) {
        int status = 0;
        enforceFile >> status;
        enforceFile.close();
        return (status == 1) ? "Enforcing" : "Permissive";
    }

    // 2. بررسی پروپرتی سیستمی اندروید
    char propValue[PROP_VALUE_MAX] = {0};
    if (__system_property_get("ro.boot.selinux", propValue) > 0) {
        return std::string(propValue);
    }

    return "Disabled/Unknown";
}

} // namespace orchestrator
