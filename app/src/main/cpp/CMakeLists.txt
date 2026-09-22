cmake_minimum_required(VERSION 3.22.1)

project("linuxorchestrator")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -Wall")

add_library(
    linuxorchestrator
    SHARED
    native-lib.cpp
    shell_executor.cpp
    root_checker.cpp
)

find_library(
    log-lib
    log
)

target_link_libraries(
    linuxorchestrator
    ${log-lib}
)
