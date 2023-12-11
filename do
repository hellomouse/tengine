#!/bin/bash
set -e
basedir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
cd "$basedir"
set -x

git submodule update --init --recursive

parallel=${parallel:-$(grep -c ^processor /proc/cpuinfo)}

function block-print() {
    echo "================================================"
    printf "$@"
    echo
    echo "================================================"
}

function build-boringssl() {
    block-print 'Compiling BoringSSL'
    cd deps/boringssl
    mkdir -p build
    cd build

    cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=1 \
        -DCMAKE_INSTALL_PREFIX='/opt/nginx' -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib' \
        -DCMAKE_INSTALL_LIBDIR='lib' ..
    ninja -j"$parallel"
    cd "$basedir"
}

function build-xquic() {
    block-print 'Compiling XQUIC'
    bssl_dir="$basedir/deps/boringssl"
    cd deps/xquic
    mkdir -p build
    cd build

    # warnings are slightly concerning, should probably report them
    cmake \
        -GNinja -DCMAKE_BUILD_TYPE=Release -DXQC_SUPPORT_SENDMMSG_BUILD=1 -DXQC_ENABLE_BBR2=1 \
        -DXQC_ENABLE_RENO=1 -DSSL_DYNAMIC=1 -DSSL_TYPE=boringssl -DSSL_PATH="$bssl_dir" \
        -DCMAKE_C_FLAGS='-Wno-error=overflow -Wno-error=dangling-pointer -Wno-error=maybe-uninitialized' \
        -DXQC_NO_PID_PACKET_PROCESS=1 -DCMAKE_BUILD_WITH_INSTALL_RPATH=1 -DCMAKE_INSTALL_RPATH='$ORIGIN' \
        ..
    ninja -j"$parallel"
    cd "$basedir"
}

function build-luajit() {
    cd deps/luajit2
    # var is overwritten by makefile instead of default
    sed -i 's/PREFIX= \/usr\/local/PREFIX= \/opt\/nginx/' Makefile
    make -j"$parallel"
    rm -rf out
    mkdir out
    make DESTDIR="$PWD/out" install
    cd "$basedir"
}

function add-module() {
    echo "--add-module=modules/$1"
}

function build-tengine() {
    # need -lpcre for lua
    # need to manually specify boringssl include/lib paths
    auto/configure \
        --with-jemalloc --with-threads --builddir=build --prefix='/opt/nginx' \
        --with-file-aio --with-http_v2_module --with-http_dav_module \
        --with-http_ssl_module --with-stream --with-stream_ssl_module --with-stream_sni \
        --with-cc-opt="-I$basedir/deps/boringssl/include -Wno-error=cast-function-type" \
        --with-ld-opt="-lpcre -L$basedir/deps/boringssl/build/ssl -L$basedir/deps/boringssl/build/crypto -Wl,-rpath,'"'$$ORIGIN'"'/../lib" \
        --with-luajit-inc="$basedir/deps/luajit2/out/opt/nginx/include/luajit-2.1" \
        --with-luajit-lib="$basedir/deps/luajit2/out/opt/nginx/lib" \
        --with-xquic-inc="$basedir/deps/xquic/include" \
        --with-xquic-lib="$basedir/deps/xquic/build" \
        --add-dynamic-module=deps/ngx-fancyindex \
        --add-dynamic-module=deps/headers-more-nginx-module \
        --add-dynamic-module=deps/njs/nginx \
        $(add-module mod_common) \
        $(add-module mod_config) \
        $(add-module mod_strategy) \
        $(add-module ngx_http_lua_module) \
        $(add-module ngx_http_reqstat_module) \
        $(add-module ngx_http_upstream_consistent_hash_module) \
        $(add-module ngx_http_upstream_check_module) \
        $(add-module ngx_http_upstream_dynamic_module) \
        $(add-module ngx_http_upstream_session_sticky_module) \
        $(add-module ngx_http_upstream_dyups_module) \
        $(add-module ngx_http_xquic_module)

    make -j"$parallel"
}

build-luajit
build-boringssl
build-xquic
build-tengine
