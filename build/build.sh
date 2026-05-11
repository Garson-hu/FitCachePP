#!/bin/bash


export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib/pkgconfig
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/home/ghu4/hvac/log4c-1.2.4/install/lib
export PATH=/home/ghu4/hvac/mercury-2.0.1/build/bin:$PATH
export LD_LIBRARY_PATH=/home/ghu4/hvac/rlibrary/mercury2.0.1/lib:$LD_LIBRARY_PATH
export C_INCLUDE_PATH=/home/ghu4/hvac/rlibrary/mercury2.0.1/include:$C_INCLUDE_PATH
export CPLUS_INCLUDE_PATH=/home/ghu4/hvac/rlibrary/mercury2.0.1/include:$CPLUS_INCLUDE_PATH
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/home/ghu4/hvac/rlibrary/mercury2.0.1/lib/pkgconfig


# cmake -DCMAKE_C_COMPILER=/opt/ohpc/pub/compiler/gcc/9.4.0/bin/gcc -DCMAKE_CXX_COMPILER=/opt/ohpc/pub/compiler/gcc/9.4.0/bin/g++ .. -DDEBUG_HU=0
#   -DCMAKE_C_COMPILER=/opt/ohpc/pub/compiler/gcc/9.4.0/bin/gcc \
#   -DCMAKE_CXX_COMPILER=/opt/ohpc/pub/compiler/gcc/9.4.0/bin/g++ \
# cmake \
#   -DCMAKE_C_COMPILER=/opt/ohpc/pub/compiler/gcc/9.4.0/bin/gcc \
#   -DCMAKE_CXX_COMPILER=/opt/ohpc/pub/compiler/gcc/9.4.0/bin/g++ \
#   -DCMAKE_BUILD_TYPE=Release \
#   -DCMAKE_C_FLAGS_RELEASE="-O3" \
#   -DCMAKE_CXX_FLAGS_RELEASE="-O3" \
#   -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
#   .. -DDEBUG_HU=1 -DTIMING=1

# make -j16

#  -g -pg"
cmake .. \
  -DCMAKE_C_COMPILER=/opt/ohpc/pub/compiler/gcc/9.4.0/bin/gcc \
  -DCMAKE_CXX_COMPILER=/opt/ohpc/pub/compiler/gcc/9.4.0/bin/g++ \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="-O3 \
  -DCMAKE_CXX_FLAGS="-O3 \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DDEBUG_HU=1 -DTIMING=1


make -j16