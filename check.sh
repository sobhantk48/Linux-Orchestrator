#!/usr/bin/env bash

# توقف خودکار در صورت بروز خطای بحرانی
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}   🔍 شروع بررسی جامع کدهای LinuxOrchestrator ${NC}"
echo -e "${BLUE}==========================================${NC}"

# 1. بررسی کدهای C++
echo -e "\n${YELLOW}[1/4] ⚙️  بررسی کدهای C++ (Native Code)...${NC}"
if [ -f "CMakeLists.txt" ] && [ ! -f "app/build.gradle.kts" ] && [ ! -f "app/build.gradle" ]; then
    echo -e "${BLUE}📁 بیلد مستقل C++ اجرا می‌شود...${NC}"
    mkdir -p build_cpp && cd build_cpp
    cmake .. -DCMAKE_BUILD_TYPE=Debug
    cmake --build . -- -j$(nproc)
    cd ..
    echo -e "${GREEN}✅ کامپایل کدهای C++ مستقل با موفقیت انجام شد.${NC}"
else
    echo -e "${BLUE}ℹ️ کدهای C++ به NDK اندروید متصل هستند؛ کامپایل در مرحله Gradle انجام خواهد شد.${NC}"
fi

if [ -n "$CPP_DIR" ]; then
    echo -e "${BLUE}📁 فایل CMake در مسیر '$CPP_DIR' پیدا شد.${NC}"
    mkdir -p build_cpp
    cd build_cpp
    cmake "../$CPP_DIR" -DCMAKE_BUILD_TYPE=Debug
    cmake --build . -- -j$(nproc)
    
    # اجرای تست‌های C++ در صورت وجود
    if ctest -N 2>/dev/null | grep -q "Total Tests: [1-9]"; then
        echo -e "${BLUE}🧪 اجرای تست‌های CTest/GTest...${NC}"
        ctest --output-on-failure
    fi
    cd ..
    echo -e "${GREEN}✅ کامپایل کدهای C++ با موفقیت انجام شد.${NC}"
else
    echo -e "${YELLOW}ℹ️ کامپایل مستقل C++ رد شد (توسط Gradle NDK بررسی خواهد شد).${NC}"
fi

# 2. بررسی Lint
echo -e "\n${YELLOW}[2/4] 🧹 اجرای بررسی استاتیک کد و خطاها (Lint)...${NC}"
if [ -f "./gradlew" ]; then
    ./gradlew lintDebug --stacktrace
    echo -e "${GREEN}✅ بررسی Lint با موفقیت پاس شد.${NC}"
else
    echo -e "${RED}❌ فایل gradlew در ریشه پروژه یافت نشد!${NC}"
    exit 1
fi

# 3. تست‌های واحد کاتلین و جاوا
echo -e "\n${YELLOW}[3/4] 📱 اجرای تست‌های واحد (Unit Tests)...${NC}"
./gradlew testDebugUnitTest
echo -e "${GREEN}✅ تمامی تست‌های جاوا و کاتلین پاس شدند.${NC}"

# 4. بیلد نهایی و بیلد نیتیو توسط Gradle
echo -e "\n${YELLOW}[4/4] 🏗️ بیلد نهایی پروژه و کامپایل NDK (Debug Build)...${NC}"
./gradlew assembleDebug
echo -e "${GREEN}✅ بیلد کامل پروژه بدون هیچ نقصی ساخته شد.${NC}"

# پیام نهایی
echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN} 🎉 عالیه! کل پروژه سالم، کامپایل‌شده و آماده Push است.${NC}"
echo -e "${GREEN}==========================================${NC}"

