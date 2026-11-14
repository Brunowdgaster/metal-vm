cmake_minimum_required(VERSION 3.16)
project(fvm C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Estratégia de dispatch. computed goto é extensão GNU: só GCC/Clang.
option(FVM_USE_GOTO "Usa computed goto no loop de dispatch (exige GCC/Clang)" OFF)
# Contagem de instruções. Desligue para medir o custo da própria instrumentação.
option(FVM_STATS    "Compila os contadores de instrucao"                      ON)

add_executable(fvm
    c/src/main.c
    c/src/vm.c
    c/src/gc.c
    c/src/asm.c
    c/src/value.c
)

target_include_directories(fvm PRIVATE c/include)

if(FVM_USE_GOTO)
    if(MSVC)
        message(FATAL_ERROR "FVM_USE_GOTO nao e suportado pelo MSVC: computed goto e extensao GNU. Use GCC ou Clang (ex.: no WSL).")
    endif()
    target_compile_definitions(fvm PRIVATE FVM_USE_GOTO)
endif()

if(FVM_STATS)
    target_compile_definitions(fvm PRIVATE FVM_STATS)
endif()

if(MSVC)
    target_compile_options(fvm PRIVATE /W4 /wd4100)
    target_compile_definitions(fvm PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(fvm PRIVATE -Wall -Wextra -Wpedantic)
endif()

enable_testing()
add_test(NAME suite
         COMMAND ${CMAKE_COMMAND} -E echo "use tests/run_tests.ps1 ou tests/run_tests.sh")
