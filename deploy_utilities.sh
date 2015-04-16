#!/bin/bash

#*******************************************************************************
# Copyright 2015 IBM
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#*******************************************************************************

# preferred method for using this code is to source this file, then call the
# appropriate function.

# uncomment the next line to debug this script
# set -x

########################################
# normalize memory size - adjust to the allowed set of memory sizes
########################################  
get_memory() {
    local CONT_SIZE=$1
    local RET_MEMORY=256
    # check for container size and set the value as MB
    if [ -z "$CONT_SIZE" ] || [ "$CONT_SIZE" == "m1.tiny" ] || [ "$CONT_SIZE" == "256" ];then
        RET_MEMORY=256
    elif [ "$CONT_SIZE" == "m1.small" ] || [ "$CONT_SIZE" == "512" ]; then
        RET_MEMORY=512
    elif [ "$CONT_SIZE" == "m1.medium" ] || [ "$CONT_SIZE" == "1024" ]; then
        RET_MEMORY=1024
    elif [ "$CONT_SIZE" == "m1.large" ] || [ "$CONT_SIZE" == "2048" ]; then
        RET_MEMORY=2048
    else
        echo -e "${red}$CONT_SIZE is an invalid value, defaulting to m1.tiny (256 MB memory) and continuing deploy process.${no_color}" >&2
        RET_MEMORY=256
    fi
    echo "$RET_MEMORY"
}


# this function expects a file "iceinfo.log" to exist in the current director, being the output of a call to 'ice info'
# example:
#    ice info > iceinfo.log 2> /dev/null
#    RESULT=$?
#    if [ $RESULT -eq 0 ]; then
#        check_memory_quota()
#        RESULT=$?
#        if [ $RESULT -ne 0 ]; then
#           echo woe is us, we have exceeded our quota
#        fi
#    fi
check_memory_quota() {
    local CONT_SIZE=$1
    local NEW_MEMORY=$(get_memory "$CONT_SIZE" 2> /dev/null)
    local MEMORY_LIMIT=$(grep "Memory limit (MB)" iceinfo.log | awk '{print $5}')
    local MEMORY_USAGE=$(grep "Memory usage (MB)" iceinfo.log | awk '{print $5}')
    if [ -z "$MEMORY_LIMIT" ] || [ -z "$MEMORY_USAGE" ]; then
        echo -e "${red}MEMORY_LIMIT or MEMORY_USAGE value is missing from ice info output command. Defaulting to m1.tiny (256 MB memory) and continuing deploy process.${no_color}" >&2
    else
        if [ $(echo "$MEMORY_LIMIT - $MEMORY_USAGE" | bc) -lt $NEW_MEMORY ]; then
            return 1
        fi
    fi
    return 0
}

# internal function, selfcheck unit test to make sure things are working
# as expected
unittest() {
    local RET=0
    RET=$(get_memory 256 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check 256)"
        return 10
    fi
    RET=$(get_memory "m1.tiny" 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check m1.tiny)"
        return 11
    fi
    RET=$(get_memory 512 2> /dev/null)
    if [ "${RET}x" != "512x" ]; then
        echo "ut fail (bad memory value on check 512)"
        return 12
    fi
    RET=$(get_memory "m1.small" 2> /dev/null)
    if [ "${RET}x" != "512x" ]; then
        echo "ut fail (bad memory value on check m1.small)"
        return 13
    fi
    RET=$(get_memory 1024 2> /dev/null)
    if [ "${RET}x" != "1024x" ]; then
        echo "ut fail (bad memory value on check 1024)"
        return 14
    fi
    RET=$(get_memory "m1.medium" 2> /dev/null)
    if [ "${RET}x" != "1024x" ]; then
        echo "ut fail (bad memory value on check m1.medium)"
        return 15
    fi
    RET=$(get_memory 2048 2> /dev/null)
    if [ "${RET}x" != "2048x" ]; then
        echo "ut fail (bad memory value on check 2048)"
        return 16
    fi
    RET=$(get_memory "m1.large" 2> /dev/null)
    if [ "${RET}x" != "2048x" ]; then
        echo "ut fail (bad memory value on check m1.large)"
        return 17
    fi
    RET=$(get_memory 4096 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check 4096)"
        return 18
    fi
    RET=$(get_memory "bad_value" 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check bad_value)"
        return 19
    fi
    RET=$(get_memory 1 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check 1)"
        return 20
    fi
    RET=$(get_memory "" 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on empty check)"
        return 21
    fi

    echo "Memory limit (MB)      : 2048" >iceinfo.log 
    echo "Memory usage (MB)      : 0" >>iceinfo.log
    $(check_memory_quota 256 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "ut fail (bad quota check with 256 size)"
        return 30
    fi

    echo "Memory limit (MB)      : 2048" >iceinfo.log 
    echo "Memory usage (MB)      : 1024" >>iceinfo.log
    $(check_memory_quota 2048 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 1 ]; then
        echo "ut fail (incorrect pass for too much memory 2048+2048)"
        return 31
    fi

    echo "Memory limit (MB)      : 2048" >iceinfo.log 
    echo "Memory usage (MB)      : 2048" >>iceinfo.log
    $(check_memory_quota 512 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 1 ]; then
        echo "ut fail (incorrect pass for too much memory 2048+512)"
        return 32
    fi
    echo "Memory limit (MB)      : 1024" >iceinfo.log 
    echo "Memory usage (MB)      : 0" >>iceinfo.log
    $(check_memory_quota 512 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "ut fail (bad quota check with 512 size)"
        return 33
    fi

    echo "Memory limit (MB)      : 2048" >iceinfo.log 
    echo "Memory usage (MB)      : 1024" >>iceinfo.log
    $(check_memory_quota -1 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "ut fail (bad quota check with -1 size)"
        return 34
    fi

    echo "Memory limit (MB)      : 2048" >iceinfo.log 
    echo "Memory usage (MB)      : 2048" >>iceinfo.log
    $(check_memory_quota -1 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 1 ]; then
        echo "incorrect pass for too much memory 2048+\"-1\")"
        return 34
    fi
    return 0
}

unittest
if [ ! $? -eq 0 ]; then
    echo "Unit test failed, aborting"
else
    # allow run the script with --get_memory parameter to check get_memory with custom parms directly
    if [ "$1" == "--get_memory" ]; then
        shift
        rc=0
        for i in $@
        do
            COMMAND="get_memory $i"
            echo "testing call \"$COMMAND\""
            $COMMAND
            rcc=$?
            if [ $rc -eq 0 ]; then
                rc=$rcc
            fi
            shift
        done
        # only exit if running directly, if done in source will
        # kill the parent shell
        echo "Return code is $rc"
        exit $rc
    fi
fi

