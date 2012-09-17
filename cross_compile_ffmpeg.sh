#!/usr/bin/env bash
################################################################################
# ffmpeg windows cross compile helper/downloader script
################################################################################
# Copyright (C) 2012 Roger Pack
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# this program.  If not, see <http://www.gnu.org/licenses/>.
#
# The GNU General Public License can be found in the LICENSE file.

yes_no_sel () {
unset user_input
local question="$1"
shift
while [[ "$user_input" != [YyNn] ]]; do
  echo -n "$question"
  read user_input
  if [[ "$user_input" != [YyNn] ]]; then
    clear; echo 'Your selection was not vaild, please try again.'; echo
  fi
done
# downcase it
user_input=$(echo $user_input | tr '[A-Z]' '[a-z]')
}

cur_dir="$(pwd)/sandbox"

intro() {
  cat <<EOL
     ##################### Welcome ######################
  Welcome to the ffmpeg cross-compile builder-helper script.
  Downloads and builds will be installed to directories within $cur_dir
  If this is not ok, then exit now, and cd to the directory where you'd
  like them installed, then run this script again.  NB that once you build
  your compilers, you can no longer rename the directory.
EOL

  yes_no_sel "Is ./sandbox ok [y/n]?"
  if [[ "$user_input" = "n" ]]; then
    exit 1
  fi
  mkdir -p "$cur_dir"
  cd "$cur_dir"
  yes_no_sel "Would you like to include non-free (non GPL compatible) libraries, like many aac encoders
The resultant binary will not be distributable, but might be useful for in-house use. Include non-free [y/n]?"
  non_free="$user_input" # save it away
  #yes_no_sel "Would you like to compile with -march=native, which can get a few percent speedup
#but also makes it so you cannot distribute the binary to machines of other architecture/cpu 
#(also note that you should only enable this if compiling on a VM on the same box you intend to target, otherwise
#it makes no sense)  Use march=native? THIS IS JUST EXPERIMENTAL AND DOES NOT WORK FULLY YET--choose n typically. [y/n]?" 
  #march_native="$user_input"
}

install_cross_compiler() {
  if [[ -f "mingw-w64-i686/compiler.done" || -f "mingw-w64-x86_64/compiler.done" ]]; then
   echo "MinGW-w64 compiler of some type already installed, not re-installing it..."
   if [[ $rebuild_compilers != "y" ]]; then
     return # early exit
   fi
  fi
  read -p 'First we will download and compile a gcc cross-compiler (MinGW-w64).
  You will be prompted with a few questions as it installs (it takes quite awhile).
  Enter to continue:'

  wget http://zeranoe.com/scripts/mingw_w64_build/mingw-w64-build-3.0.6 -O mingw-w64-build-3.0.6
  chmod u+x mingw-w64-build-3.0.6
  ./mingw-w64-build-3.0.6 --mingw-w64-ver=2.0.4 --disable-nls --disable-shared --default-configure --clean-build || exit 1 # --disable-shared allows c++ to be distributed at all...
  if [ -d mingw-w64-x86_64 ]; then
    touch mingw-w64-x86_64/compiler.done
  fi
  if [ -d mingw-w64-i686 ]; then
    touch mingw-w64-i686/compiler.done
  fi
  clear
  echo "Ok, done building MinGW-w64 cross-compiler..."
}

setup_env() {
  export PKG_CONFIG_LIBDIR= # disable pkg-config from reverting back to and finding system installed packages [yikes]
}

do_svn_checkout() {
  repo_url="$1"
  to_dir="$2"
  if [ ! -d $to_dir ]; then
    echo "svn checking out to $to_dir"
    svn checkout $repo_url $to_dir.tmp || exit 1
    mv $to_dir.tmp $to_dir
  else
    cd $to_dir
    echo "Updating $to_dir"
    svn up
    cd ..
  fi
}

do_git_checkout() {
  repo_url="$1"
  to_dir="$2"
  if [ ! -d $to_dir ]; then
    echo "Downloading (via git clone) $to_dir"
    # prevent partial checkouts by renaming it only after success
    git clone $repo_url $to_dir.tmp || exit 1
    mv $to_dir.tmp $to_dir
    echo "done downloading $to_dir"
  else
    cd $to_dir
    echo "Updating to latest $to_dir version..."
    old_git_version=`git rev-parse HEAD`
    git pull
    new_git_version=`git rev-parse HEAD`
    if [[ "$old_git_version" != "$new_git_version" ]]; then
     echo "got upstream changes, forcing reconfigure."
     rm already*
    fi 
    cd ..
  fi
}

do_configure() {
  configure_options="$1"
  configure_name="$2"
  if [[ "$configure_name" = "" ]]; then
    configure_name="./configure"
  fi
  local cur_dir2=$(pwd)
  local english_name=$(basename $cur_dir2)
  local touch_name=$(echo -- $configure_options | /usr/bin/env md5sum) # sanitize, disallow too long of length
  touch_name=$(echo already_configured_$touch_name | sed "s/ //g") # add prefix so we can delete it easily, remove spaces
  if [ ! -f "$touch_name" ]; then
    echo "configuring $english_name as $ PATH=$PATH $configure_name $configure_options"
    make clean # just in case
    #make uninstall # does weird things when used with ffmpeg
    if [ -f bootstrap.sh ]; then
      ./bootstrap.sh
    fi
    rm -f already_configured* # any old configuration options, since they'll be out of date after the next configure
    rm -f already_ran_make
    "$configure_name" $configure_options || exit 1
    touch -- "$touch_name"
    make clean # just in case
  else
    echo "already configured $(basename $cur_dir2)" 
  fi
}

do_make() {
  local cur_dir2=$(pwd)
  if [ ! -f already_ran_make ]; then
    echo "making $cur_dir2 as $ PATH=$PATH make $extra_make_options"
    make $extra_make_options || exit 1
    touch already_ran_make
  else
    echo "already did make $(basename "$cur_dir2")"
  fi
}

do_make_install() {
  extra_make_options="$1"
  do_make $extra_make_options
  if [ ! -f already_ran_make_install ]; then
    echo "make installing $cur_dir2 as $ PATH=$PATH make install $extra_make_options"
    make install $extra_make_options || exit 1
    touch already_ran_make_install
  fi
}

build_x264() {
  do_git_checkout "http://repo.or.cz/r/x264.git" "x264"
  cd x264
  do_configure "--host=$host_target --enable-static --cross-prefix=$cross_prefix --prefix=$mingw_w64_x86_64_prefix --enable-win32thread --enable-debug"
  # TODO more march=native here?
  # rm -f already_ran_make # just in case the git checkout did something, re-make
  do_make_install
  cd ..
}


build_librtmp() {
  #  download_and_unpack_file http://rtmpdump.mplayerhq.hu/download/rtmpdump-2.3.tgz rtmpdump-2.3
  #  cd rtmpdump-2.3/librtmp

  do_git_checkout "http://repo.or.cz/r/rtmpdump.git" rtmpdump_git
  cd rtmpdump_git/librtmp
  make install CRYPTO=GNUTLS OPT='-O2 -g' "CROSS_COMPILE=$cross_prefix" SHARED=no "prefix=$mingw_w64_x86_64_prefix" || exit 1
  cd ../..
}

build_libopenjpeg() {
  # TRUNK didn't seem to build right...
  #do_svn_checkout http://openjpeg.googlecode.com/svn/trunk/ openjpeg
  #cd openjpeg
  #generic_configure
  #do_make_install
  #cd ..
  download_and_unpack_file http://openjpeg.googlecode.com/files/openjpeg_v1_4_sources_r697.tgz openjpeg_v1_4_sources_r697
  cd openjpeg_v1_4_sources_r697
  generic_configure
  sed -i "s/\/usr\/lib/\$\(libdir\)/" Makefile # install pkg_config to the right dir...
  do_make_install
  cd .. 
}

build_libvpx() {
  download_and_unpack_file http://webm.googlecode.com/files/libvpx-v1.1.0.tar.bz2 libvpx-v1.1.0
  cd libvpx-v1.1.0
  export CROSS="$cross_prefix"
  if [[ "$bits_target" = "32" ]]; then
    do_configure "--target=generic-gnu --prefix=$mingw_w64_x86_64_prefix --enable-static --disable-shared"
  else
    do_configure "--target=generic-gnu --prefix=$mingw_w64_x86_64_prefix --enable-static --disable-shared"
  fi
  do_make_install "extralibs='-lpthread'" # weird
  cd ..
}

build_utvideo() {
  download_and_unpack_file https://github.com/downloads/rdp/FFmpeg/utvideo-11.1.0-src.zip utvideo-11.1.0 # local copy :)
  cd utvideo-11.1.0
    patch -f -p0 < ../../../utv.diff
    make install CROSS_PREFIX=$cross_prefix DESTDIR=$mingw_w64_x86_64_prefix prefix=
  cd ..
}

download_and_unpack_file() {
  url="$1"
  output_name=$(basename $url)
  output_dir="$2"
  if [ ! -f "$output_dir/unpacked.successfully" ]; then
    wget "$url" -O "$output_name" || exit 1
    tar -xf "$output_name" || unzip $output_name || exit 1
    touch "$output_dir/unpacked.successfully"
    rm "$output_name"
  fi
}

generic_configure() {
  local extra_configure_options="$1"
  do_configure "--host=$host_target --prefix=$mingw_w64_x86_64_prefix --disable-shared --enable-static $extra_configure_options"
}

# needs 2 parameters currently
generic_download_and_install() {
  local url="$1"
  local english_name="$2" 
  local extra_configure_options="$3"
  download_and_unpack_file $url $english_name
  cd $english_name || exit "needs 2 parameters"
  generic_configure $extra_configure_options
  do_make_install
  cd ..
}

build_libflite() {
  download_and_unpack_file http://www.speech.cs.cmu.edu/flite/packed/flite-1.4/flite-1.4-release.tar.bz2 flite-1.4-release
  cd flite-1.4-release
   sed -i "s|i386-mingw32-|$cross_prefix|" configure*
   generic_configure
   do_make
   make install # it fails in error...
   cp ./build/i386-mingw32/lib/*.a $mingw_w64_x86_64_prefix/lib || exit 1
  cd ..
}

build_libgsm() {
  download_and_unpack_file http://www.quut.com/gsm/gsm-1.0.13.tar.gz gsm-1.0-pl13
  cd gsm-1.0-pl13
  make CC=${cross_prefix}gcc AR=${cross_prefix}ar RANLIB=${cross_prefix}ranlib INSTALL_ROOT=${mingw_w64_x86_64_prefix} # fails, but we expect that LODO fix [?]
  cp lib/libgsm.a $mingw_w64_x86_64_prefix/lib || exit 1
  mkdir -p $mingw_w64_x86_64_prefix/include/gsm
  cp inc/gsm.h $mingw_w64_x86_64_prefix/include/gsm || exit 1
  cd ..
}

build_libopus() {
  generic_download_and_install http://downloads.xiph.org/releases/opus/opus-1.0.1.tar.gz opus-1.0.1 
}

build_libogg() {
  generic_download_and_install http://downloads.xiph.org/releases/ogg/libogg-1.3.0.tar.gz libogg-1.3.0
}

build_libvorbis() {
  generic_download_and_install http://downloads.xiph.org/releases/vorbis/libvorbis-1.2.3.tar.gz libvorbis-1.2.3
}

build_libspeex() {
  generic_download_and_install http://downloads.xiph.org/releases/speex/speex-1.2rc1.tar.gz speex-1.2rc1
}  

build_libtheora() {
  generic_download_and_install http://downloads.xiph.org/releases/theora/libtheora-1.1.1.tar.bz2 libtheora-1.1.1
}

build_libfribidi() {
  download_and_unpack_file http://fribidi.org/download/fribidi-0.19.4.tar.bz2 fribidi-0.19.4
  cd fribidi-0.19.4
    # export symbols right...
    patch -f -p0 <<EOL # patch command can fail, which is ok...
--- lib/fribidi-common.h	2008-02-04 21:30:46.000000000 +0000
+++ lib/fribidi-common.h	2008-02-04 21:32:25.000000000 +0000
@@ -53,11 +53,7 @@
 
 /* FRIBIDI_ENTRY is a macro used to declare library entry points. */
 #ifndef FRIBIDI_ENTRY
-# if (defined(WIN32)) || (defined(_WIN32_WCE))
-#  define FRIBIDI_ENTRY __declspec(dllimport)
-# else /* !WIN32 */
 #  define FRIBIDI_ENTRY		/* empty */
-# endif	/* !WIN32 */
 #endif /* !FRIBIDI_ENTRY */
 
 #if FRIBIDI_USE_GLIB+0

EOL
  generic_configure
  do_make_install
  cd ..
}

build_libass() {
  generic_download_and_install http://libass.googlecode.com/files/libass-0.10.0.tar.gz libass-0.10.0
  sed -i 's/-lass -lm/-lass -lfribidi -lm/' "$PKG_CONFIG_PATH/libass.pc"
}

build_gmp() {
  download_and_unpack_file ftp://ftp.gnu.org/gnu/gmp/gmp-5.0.5.tar.bz2 gmp-5.0.5
  cd gmp-5.0.5
    generic_configure "ABI=$bits_target"
    do_make_install
  cd .. 
}

build_gnutls() {
  download_and_unpack_file ftp://ftp.gnu.org/gnu/gnutls/gnutls-3.0.22.tar.xz gnutls-3.0.22
  cd gnutls-3.0.22
    generic_configure "--disable-cxx" # don't need the c++ version, in an effort to cut down on size... LODO test difference...
    do_make_install
  cd ..
  sed -i 's/-lgnutls *$/-lgnutls -lnettle -lhogweed -lgmp -lcrypt32/' "$PKG_CONFIG_PATH/gnutls.pc"
}

build_libnettle() {
  generic_download_and_install http://www.lysator.liu.se/~nisse/archive/nettle-2.5.tar.gz nettle-2.5
}

build_zlib() {
  download_and_unpack_file http://zlib.net/zlib-1.2.7.tar.gz zlib-1.2.7
  cd zlib-1.2.7
    do_configure "--static --prefix=$mingw_w64_x86_64_prefix"
    do_make_install "CC=$(echo $cross_prefix)gcc AR=$(echo $cross_prefix)ar RANLIB=$(echo $cross_prefix)ranlib"
  cd ..
}

build_libxvid() {
  download_and_unpack_file http://downloads.xvid.org/downloads/xvidcore-1.3.2.tar.gz xvidcore
  cd xvidcore/build/generic
  if [ "$bits_target" = "64" ]; then
    local config_opts="--build=x86_64-unknown-linux-gnu --disable-assembly" # kludgey work arounds for 64 bit
  fi
  do_configure "--host=$host_target --prefix=$mingw_w64_x86_64_prefix $config_opts" # no static option...
  sed -i "s/-mno-cygwin//" platform.inc # remove old compiler flag that now apparently breaks us
  do_make_install
  cd ../../..
  # force a static build after the fact
  if [[ -f "$mingw_w64_x86_64_prefix/lib/xvidcore.dll" ]]; then
    rm $mingw_w64_x86_64_prefix/lib/xvidcore.dll || exit 1
    mv $mingw_w64_x86_64_prefix/lib/xvidcore.a $mingw_w64_x86_64_prefix/lib/libxvidcore.a || exit 1
  fi
}

build_fontconfig() {
  download_and_unpack_file http://www.freedesktop.org/software/fontconfig/release/fontconfig-2.10.1.tar.gz fontconfig-2.10.1
  cd fontconfig-2.10.1
    generic_configure --disable-docs
    do_make_install
  cd .. 
  sed -i 's/-L${libdir} -lfontconfig[^l]*$/-L${libdir} -lfontconfig -lfreetype -lexpat/' "$PKG_CONFIG_PATH/fontconfig.pc"
}

build_openssl() {
  download_and_unpack_file http://www.openssl.org/source/openssl-1.0.1c.tar.gz openssl-1.0.1c
  cd openssl-1.0.1c
  export cross="$cross_prefix"
  export CC="${cross}gcc"
  export AR="${cross}ar"
  export RANLIB="${cross}ranlib"
  if [ "$bits_target" = "32" ]; then
    do_configure "--prefix=$mingw_w64_x86_64_prefix no-shared mingw" ./Configure
  else
    do_configure "--prefix=$mingw_w64_x86_64_prefix no-shared mingw64" ./Configure
  fi
  do_make_install
  unset cross
  unset CC
  unset AR
  unset RANLIB
  cd ..
}

build_fdk_aac() {
  generic_download_and_install http://sourceforge.net/projects/opencore-amr/files/fdk-aac/fdk-aac-0.1.0.tar.gz/download fdk-aac-0.1.0
}

build_libexpat() {
  generic_download_and_install http://sourceforge.net/projects/expat/files/expat/2.1.0/expat-2.1.0.tar.gz/download expat-2.1.0
}


build_freetype() {
  generic_download_and_install http://download.savannah.gnu.org/releases/freetype/freetype-2.4.10.tar.gz freetype-2.4.10
} 

build_vo_aacenc() {
  generic_download_and_install http://sourceforge.net/projects/opencore-amr/files/vo-aacenc/vo-aacenc-0.1.2.tar.gz/download vo-aacenc-0.1.2
}

build_sdl() {
  # apparently ffmpeg expects prefix-sdl-config not sdl-config that they give us, so rename...
  export CFLAGS= # avoid segfault when running ffplay...
  generic_download_and_install http://www.libsdl.org/release/SDL-1.2.15.tar.gz SDL-1.2.15
  unset CFLAGS
  mkdir temp
  cd temp # so paths will work out right
  local prefix=$(basename $cross_prefix)
  local bin_dir=$(dirname $cross_prefix)
  sed -i "s/-mwindows//" "$mingw_w64_x86_64_prefix/bin/sdl-config" # allow ffmpeg to output anything
  sed -i "s/-mwindows//" "$PKG_CONFIG_PATH/sdl.pc"
  cp "$mingw_w64_x86_64_prefix/bin/sdl-config" "$bin_dir/${prefix}sdl-config" # this is the only one in the PATH so use it for now
  cd ..
  rmdir temp
}

build_faac() {
  generic_download_and_install http://downloads.sourceforge.net/faac/faac-1.28.tar.gz faac-1.28 "--with-mp4v2=no"
}

build_lame() {
  generic_download_and_install http://sourceforge.net/projects/lame/files/lame/3.99/lame-3.99.5.tar.gz/download lame-3.99.5
}


build_ffmpeg() {
  do_git_checkout https://github.com/FFmpeg/FFmpeg.git ffmpeg_git
  cd ffmpeg_git
  if [ "$bits_target" = "32" ]; then
   local arch=x86
  else
   local arch=x86_64
  fi

  config_options="--enable-memalign-hack --arch=$arch --enable-gpl --enable-libx264 --enable-avisynth --enable-libxvid --target-os=mingw32  --cross-prefix=$cross_prefix --pkg-config=pkg-config --enable-libmp3lame --enable-version3 --enable-libvo-aacenc --enable-libvpx --extra-libs=-lws2_32 --extra-libs=-lpthread --enable-zlib --extra-libs=-lwinmm --extra-libs=-lgdi32 --enable-librtmp --enable-libvorbis --enable-libtheora --enable-libspeex --enable-libopenjpeg --enable-gnutls --enable-libgsm --enable-libfreetype --disable-optimizations --enable-mmx --disable-postproc --enable-fontconfig --enable-libass --enable-libutvideo --enable-libopus"
  if [[ "$non_free" = "y" ]]; then
    config_options="$config_options --enable-nonfree --enable-libfdk-aac" # --enable-libfaac -- faac too poor quality and becomes the default -- add it in and uncomment the build_faac line to include it --enable-openssl
  else
    config_options="$config_options"
  fi

  if [[ "$native_build" = "y" ]]; then
    config_options="$config_options --disable-runtime-cpudetect"
    # TODO --cpu=host ...
  else
    config_options="$config_options --enable-runtime-cpudetect"
  fi
  
  do_configure "$config_options"
  rm -f *.exe # just in case some library dependency was updated, force it to re-link
  echo "ffmpeg: doing PATH=$PATH make"
  make || exit 1
  local cur_dir2=$(pwd)
  echo "Done! You will find $bits_target bit binaries in $cur_dir2/ff{mpeg,probe,play}*.exe"
  cd ..
}

build_all() {
  build_zlib # rtmp depends on it [as well as ffmpeg's optional but handy --enable-zlib]
  build_gmp
  build_libnettle # needs gmp
  build_gnutls # needs libnettle
  #build_libflite # disabled till I can figure out how to get it to work in 64 bit
  build_libgsm
  build_sdl # needed for ffplay to be created
  build_libopus
  build_libogg
  build_libspeex # needs libogg for exe's
  build_libvorbis # needs libogg
  build_libtheora # needs libvorbis, libogg
  build_libxvid
  build_x264
  build_lame
  build_libvpx
  build_vo_aacenc
  build_utvideo
  build_freetype
  build_libexpat
  build_fontconfig # needs expat, might need freetype
  build_libfribidi
  build_libass # needs freetype, needs fribidi, needs fontconfig
  build_libopenjpeg
  if [[ "$non_free" = "y" ]]; then
    build_fdk_aac
    # build_faac # not included for now, too poor quality :)
  fi
  build_librtmp # needs gnutls
  #build_openssl # hopefully don't need it anymore...
  build_ffmpeg
}


while true; do
  case $1 in
    -h | --help ) echo "options: --rebuild-compilers=y"; exit 0 ;;
    --rebuild-compilers=* ) rebuild_compilers="${1#*=}"; shift ;;
    -- ) shift; break ;;
    -* ) echo "Error, unknown option: '$1'."; exit 1 ;;
    * ) break ;;
  esac
done

intro # remember to always run the intro, since it adjust pwd
install_cross_compiler # always run this, too, since it adjust the PATH
setup_env

original_path="$PATH"
if [ -d "mingw-w64-i686" ]; then # they installed a 32-bit compiler
  echo "Building 32-bit ffmpeg..."
  host_target='i686-w64-mingw32'
  mingw_w64_x86_64_prefix="$cur_dir/mingw-w64-i686/$host_target"
  export PATH="$cur_dir/mingw-w64-i686/bin:$original_path"
  export PKG_CONFIG_PATH="$cur_dir/mingw-w64-i686/i686-w64-mingw32/lib/pkgconfig"
  bits_target=32
  cross_prefix="$cur_dir/mingw-w64-i686/bin/i686-w64-mingw32-"
  mkdir -p win32
  cd win32
  build_all
  cd ..
fi

if [ -d "mingw-w64-x86_64" ]; then # they installed a 64-bit compiler
  echo "Building 64-bit ffmpeg..."
  host_target='x86_64-w64-mingw32'
  mingw_w64_x86_64_prefix="$cur_dir/mingw-w64-x86_64/$host_target"
  export PATH="$cur_dir/mingw-w64-x86_64/bin:$original_path"
  export PKG_CONFIG_PATH="$cur_dir/mingw-w64-x86_64/x86_64-w64-mingw32/lib/pkgconfig"
  mkdir -p x86_64
  bits_target=64
  cross_prefix="$cur_dir/mingw-w64-x86_64/bin/x86_64-w64-mingw32-"
  cd x86_64
  build_all
  cd ..
fi

echo 'done with ffmpeg cross compiler script'
