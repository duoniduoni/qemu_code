#!/bin/sh
#
# this script is used to rebuild all QEMU binaries for the host
# platforms.
#
# assume that the device tree is in TOP
#

set -e
export LANG=C
export LC_ALL=C

PROGDIR=$(dirname "$0")
VERBOSE=1

MINGW=
NO_TESTS=
OUT_DIR=objs
HELP=

for OPT; do
    case $OPT in
        --sdk-build-number=*)
            ANDROID_SDK_TOOLS_BUILD_NUMBER=${OPT##--sdk-build-number=}
            ;;
        --aosp-prebuilts-dir=*)
            ANDROID_EMULATOR_PREBUILTS_DIR=${OPT##--aosp-prebuilts-dir=}
            ;;
        --mingw)
            MINGW=true
            ;;
        --verbose)
            VERBOSE=$(( $VERBOSE + 1 ))
            ;;
        --verbosity=*)
            VERBOSE=${OPT##--verbosity=}
            ;;
        --no-tests)
            NO_TESTS=true
            ;;
        --out-dir=*)
            OUT_DIR=${OPT##--out-dir=}
            ;;
        --help|-?)
            VERBOSE=2
            HELP=y
            ;;
        --debug)
            OPTDEBUG=true
            ;;
    esac
done

panic () {
    # don't print error message if we just came back from printing the help message
   if [ -z "$HELP" ]; then
       echo "ERROR: $@"
   fi
   exit 1
}

run () {
    if [ "$VERBOSE" -gt 2 ]; then
        echo "COMMAND: $@"
        "$@"
    elif [ "$VERBOSE" -gt 1 ]; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}

log () {
    if [ "$VERBOSE" -gt 1 ]; then
        printf "%s\n" "$*"
    fi
}

HOST_OS=$(uname -s)
case $HOST_OS in
    Linux)
        HOST_NUM_CPUS=`cat /proc/cpuinfo | grep processor | wc -l`
        ;;
    Darwin|FreeBSD)
        HOST_NUM_CPUS=`sysctl -n hw.ncpu`
        ;;
    CYGWIN*|*_NT-*)
        HOST_NUM_CPUS=$NUMBER_OF_PROCESSORS
        ;;
    *)  # let's play safe here
        HOST_NUM_CPUS=1
esac

# Return the type of a given file, using the /usr/bin/file command.
# $1: executable path.
# Out: file type string, or empty if the path is wrong.
get_file_type () {
    /usr/bin/file "$1" 2>/dev/null
}

# Return true iff the file type string |$1| contains the expected
# substring |$2|.
# $1: executable file type
# $2: expected file type substring
check_file_type_substring () {
    printf "%s\n" "$1" | grep -q -E -e "$2"
}

# Define EXPECTED_32BIT_FILE_TYPE and EXPECTED_64BIT_FILE_TYPE depending
# on the current target platform. Then EXPECTED_EMULATOR_BITNESS and
# EXPECTED_EMULATOR_FILE_TYPE accordingly.
if [ "$MINGW" ]; then
    EXPECTED_32BIT_FILE_TYPE="PE32 executable \(console\) Intel 80386"
    EXPECTED_64BIT_FILE_TYPE="PE32\+ executable \(console\) x86-64"
    EXPECTED_EMULATOR_BITNESS=32
    EXPECTED_EMULATOR_FILE_TYPE=$EXPECTED_32BIT_FILE_TYPE
    TARGET_OS=windows
elif [ "$HOST_OS" = "Darwin" ]; then
    EXPECTED_64BIT_FILE_TYPE="Mach-O 64-bit executable x86_64"
    EXPECTED_EMULATOR_BITNESS=64
    EXPECTED_EMULATOR_FILE_TYPE=$EXPECTED_64BIT_FILE_TYPE
    TARGET_OS=darwin
else
    EXPECTED_64BIT_FILE_TYPE="ELF 64-bit LSB +executable, x86-64"
    EXPECTED_EMULATOR_BITNESS=64
    EXPECTED_EMULATOR_FILE_TYPE=$EXPECTED_64BIT_FILE_TYPE
    TARGET_OS=linux
fi


# Let's not remove the build directory when someone asks for help
if [ -z "$HELP" ]; then
    cd "$PROGDIR"/..
    rm -rf "$OUT_DIR"
fi
# If the user only wants to print the help message and exit
# there is no point of printing Configuring Build
if [ "$VERBOSE" -ne 2 ]; then
    echo "Configuring build."
fi
export IN_ANDROID_REBUILD_SH=1
run android/configure.sh --out-dir=$OUT_DIR "$@" $OPT_CLANG ||
    panic "Configuration error, please run ./android/configure.sh to see why."

CONFIG_MAKE=$OUT_DIR/build/config.make
if [ ! -f "$CONFIG_MAKE" ]; then
    panic "Cannot find: $CONFIG_MAKE"
fi

echo "Building sources."
run make -j$HOST_NUM_CPUS BUILD_OBJS_DIR="$OUT_DIR" ||
    panic "Could not build sources, please run 'make' to see why."

RUN_EMUGEN_TESTS=true
RUN_GEN_ENTRIES_TESTS=true

EXE_SUFFIX=

if [ "$MINGW" ]; then
    EXE_SUFFIX=.exe
fi

# Return the minimum OS X version that a Darwin binary targets.
# $1: executable path
# Out: minimum version (e.g. '10.8') or empty string on error.
darwin_min_version () {
    otool -l "$1" 2>/dev/null | awk \
          'BEGIN { CMD="" } $1 == "cmd" { CMD=$2 } $1 == "version" && CMD == "LC_VERSION_MIN_MACOSX" { print $2 }'
}

OSX_DEPLOYMENT_TARGET=10.8

# List all executables to check later.
EXECUTABLES="emulator emulator64-arm emulator64-x86 emulator64-mips"
if [ "$HOST_OS" = "Linux" ]; then
  if [ -z "$MINGW" ]; then
    EXECUTABLES="$EXECUTABLES emulator-arm emulator-x86 emulator-mips"
  fi
fi

if [ -z "$NO_TESTS" ]; then
    echo "Running tests"
    run make tests BUILD_OBJS_DIR="$OUT_DIR" ||
        panic "Failed to run unit tests, run make tests to see why."

    FAILURES=""

    echo "Checking for 'emulator' launcher program."
    EMULATOR=$OUT_DIR/emulator$EXE_SUFFIX
    if [ ! -f "$EMULATOR" ]; then
        echo "    - FAIL: $EMULATOR is missing!"
        FAILURES="$FAILURES emulator"
    fi

    echo "Checking that 'emulator' is a $EXPECTED_EMULATOR_BITNESS-bit program."
    EMULATOR_FILE_TYPE=$(get_file_type "$EMULATOR")
    if ! check_file_type_substring "$EMULATOR_FILE_TYPE" "$EXPECTED_EMULATOR_FILE_TYPE"; then
        echo "    - FAIL: $EMULATOR is not a 32-bit executable!"
        echo "        File type: $EMULATOR_FILE_TYPE"
        echo "        Expected : $EXPECTED_EMULATOR_FILE_TYPE"
        FAILURES="$FAILURES emulator-bitness-check"
    fi

    if [ "$HOST_OS" = "Darwin" ]; then
        echo "Checking that Darwin binaries target OSX $OSX_DEPLOYMENT_TARGET"
        for EXEC in $EXECUTABLES; do
            MIN_VERSION=$(darwin_min_version "$OUT_DIR/$EXEC")
            if [ "$MIN_VERSION" != "$OSX_DEPLOYMENT_TARGET" ]; then
                echo "   - FAIL: $EXEC targets [$MIN_VERSION], expected [$OSX_DEPLOYMENT_TARGET]"
                FAILURES="$FAILURES $EXEC-darwin-target"
            fi
        done
    fi


    if [ "$RUN_EMUGEN_TESTS" ]; then
        EMUGEN_UNITTESTS=$OUT_DIR/build/intermediates64/emugen_unittests/emugen_unittests
        if [ ! -f "$EMUGEN_UNITTESTS" ]; then
            echo "FAIL: Missing binary: $EMUGEN_UNITTESTS"
            FAILURES="$FAILURES emugen_unittests-binary"
        else
            echo "Running emugen_unittests."
            run $EMUGEN_UNITTESTS ||
                FAILURES="$FAILURES emugen_unittests"
        fi
        echo "Running emugen regression test suite."
        # Note that the binary is always built for the 'build' machine type,
        # I.e. if --mingw is used, it's still a Linux executable.
        EMUGEN=$OUT_DIR/build/intermediates64/emugen/emugen
        if [ ! -f "$EMUGEN" ]; then
            echo "FAIL: Missing 'emugen' binary: $EMUGEN"
            FAILURES="$FAILURES emugen-binary"
        else
            # The first case is for a remote build with package-release.sh
            TEST_SCRIPT=$PROGDIR/../opengl/host/tools/emugen/tests/run-tests.sh
            if [ ! -f "$TEST_SCRIPT" ]; then
                # This is the usual location.
                TEST_SCRIPT=$PROGDIR/android-emugl/host/tools/emugen/tests/run-tests.sh
            fi
            if [ ! -f "$TEST_SCRIPT" ]; then
                echo " FAIL: Missing script: $TEST_SCRIPT"
                FAILURES="$FAILURES emugen-test-script"
            else
                run $TEST_SCRIPT --emugen=$EMUGEN ||
                    FAILURES="$FAILURES emugen-test-suite"
            fi
        fi
    fi

    # Check the gen-entries.py script.
    if [ "$RUN_GEN_ENTRIES_TESTS" ]; then
        echo "Running gen-entries.py test suite."
        run android/scripts/tests/gen-entries/run-tests.sh ||
            FAILURES="$FAILURES gen-entries_tests"
    fi

    # Check that the windows executables all have icons.
    # First need to locate the windres tool.
    if [ "$MINGW" ]; then
        echo "Checking windows executables icons."
        if [ ! -f "$CONFIG_MAKE" ]; then
            echo "FAIL: Could not find \$CONFIG_MAKE !?"
            FAILURES="$FAILURES out-dir-config-make"
        else
            WINDRES=$(awk '/^BUILD_TARGET_WINDRES:=/ { print $2; } $1 == "BUILD_TARGET_WINDRES" { print $3; }' $CONFIG_MAKE) ||
            if true; then
                echo "FAIL: Could not find host 'windres' program"
                FAILURES="$FAILURES host-windres"
            fi
            EXPECTED_ICONS=14
            for EXEC in $EXECUTABLES; do
                EXEC=${EXEC}.exe
                if [ ! -f "$OUT_DIR"/$EXEC ]; then
                    echo "FAIL: Missing windows executable: $EXEC"
                    FAILURES="$FAILURES windows-$EXEC"
                else
                    NUM_ICONS=$($WINDRES --input-format=coff --output-format=rc $OUT_DIR/$EXEC | grep RT_ICON | wc -l)
                    if [ "$NUM_ICONS" != "$EXPECTED_ICONS" ]; then
                        echo "FAIL: Invalid icon count in $EXEC ($NUM_ICONS, expected $EXPECTED_ICONS)"
                        FAILURES="$FAILURES windows-$EXEC-icons"
                    fi
                fi
            done
        fi
    fi
    if [ "$FAILURES" ]; then
        panic "Unit test failures: $FAILURES"
    fi
else
    echo "Ignoring unit tests suite."
fi

echo "Done. !!"
