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
#set -x

debugme() {
  [[ $DEBUG = 1 ]] && "$@" || :
}

###################################################################
# protect against logging functions not being loaded              #
#    An older version of the extension will not have them loaded  #
#    Will default to just performing an echo with colors          #
###################################################################
if [[ ! "$(declare -f -F log_and_echo)" ]]; then
    echo "Setting up log_and_echo to just echo with color"
    INFO="INFO_LEVEL"
    LABEL="LABEL_LEVEL"
    WARN="WARN_LEVEL"
    ERROR="ERROR_LEVEL"

    INFO_LEVEL=4
    WARN_LEVEL=2
    ERROR_LEVEL=1
    OFF_LEVEL=0
    
    log_and_echo() {
        local MSG_TYPE="$1"
        if [ "$INFO" == "$MSG_TYPE" ]; then
            shift
            local pre=""
            local post=""
        elif [ "$LABEL" == "$MSG_TYPE" ]; then
            shift
            local pre="${label_color}"
            local post="${no_color}"
        elif [ "$WARN" == "$MSG_TYPE" ]; then
            shift
            local pre="${label_color}"
            local post="${no_color}"
        elif [ "$ERROR" == "$MSG_TYPE" ]; then
            shift
            local pre="${red}"
            local post="${no_color}"
        else
            #NO MSG type specified; fall through to INFO level
            #Do not shift
            local pre=""
            local post=""
        fi
        local L_MSG=`echo -e "$*"`
        echo -e "${pre}${L_MSG}${post}"
    }
fi


###################################################################
# get list of container data in json format
#   this function gets the group container data in json format.
# output:
#   data: group container data in json
###################################################################
get_group_container_data_json() {
    ice_retry_save_output --verbose group list >&2
    local RESULT=$?
    if [ $RESULT -eq 0 ]; then
        local data=$(sed -n '/{/,/}/p' iceretry.log)
        if [ -z "${data}" ]; then
            return 1
        else
            echo ${data}
            return 0
        fi
    else
        return 1
    fi               

}

###################################################################
# get_list_container_group_value_for_given_attribute
#   this function will search for the list of the container group value of the give attribute.
# input: 
#   attribute: the attribute of the container data
#   search_value: part of the value that used for the search
# output:
#   container_value_list: array of the value for the give key and given the search_value
###################################################################
get_list_container_group_value_for_given_attribute() {
    local attribute=$1
    local search_value=$2
    if [ -z "${attribute}" ] || [ -z "${search_value}" ]; then
        return 1
    fi
    local counter=0
    local index=2
    local container_data="unknown"
    export container_value_list=()
    local container_data_list=$(get_group_container_data_json)
    local RESULT=$?
    if [ $RESULT -ne 0 ] || [ -z "${container_data_list}" ]; then
        return 1
    fi
    while :
    do   
        local container_data=$(echo $container_data_list | awk -F'[{}]' '{print $'$index';}')
        if [ -z "${container_data}" ]; then
            break
        fi
        local container_name=$(echo $container_data | awk -F''$attribute'":' '{print $2;}' | awk -F'"' '{print $2;}') 
        if [ "${container_name%_*}" == "${search_value}" ]; then
    	    container_value_list[$counter]=$container_name
        fi
        let counter=counter+1;
        let index=index+2;
    done 
    echo ${container_value_list[@]}
    return 0
}

###################################################################
# get_container_group_value_for_given_attribute
#   this function will search for the value of the give attribute of the container data formatted in json.
# input: 
#   attribute: the attribute of the container data
#   value: value of the give attribute
#   search_attribute: the attribute that used to find the require value
# output:
#   require_value: the value for the give search_attribute
###################################################################
get_container_group_value_for_given_attribute() {
    local attribute=$1
    local value=$2
    local search_attribute=$3
    if [ -z "${attribute}" ] || [ -z "${value}" ] || [ -z "${search_attribute}" ]; then
        return 1
    fi
    local index=2
    local container_data="unknown"
    local container_data_list=$(get_group_container_data_json)
    local RESULT=$?
    if [ $RESULT -ne 0 ] || [ -z "${container_data_list}" ]; then
        return 1
    fi
    while :
    do   
        local container_data=$(echo $container_data_list | awk -F'[{}]' '{print $'$index';}')
        if [ -z "${container_data}" ]; then
            log_and_echo "$ERROR" "Container ${value} does not exist in output of the 'ice --verbose group list' command."
            break
        fi
        local container_name=$(echo $container_data | awk -F''$attribute'":' '{print $2;}' | awk -F'"' '{print $2;}') 
        if [ "${container_name}" == "${value}" ]; then
            export require_value=$(echo $container_data | awk -F''$search_attribute'":' '{print $2;}' | awk -F'"' '{print $2;}')
            RESULT=$?
            if [ $RESULT -ne 0 ] || [ -z "${require_value}" ]; then
                log_and_echo "$ERROR" "Failed to get ${search_attribute} value, return code = ${RESULT}"
                return 1
            else
    	        return 0
            fi
        fi            
        let index=index+2;
    done 
    export require_value=""
    return 1
}

###################################################################
# get port numbers
###################################################################
get_port_numbers() {
    local PORT_NUM=$1
    local RETVAL=""
    local OIFS=$IFS
    # check for port as a number separate by commas and replace commas with --publish
    check_num='^[[:digit:][:space:],,]+$'
    if ! [[ "$PORT_NUM" =~ $check_num ]] ; then
        echo -e "${red}PORT value is not a number. It should be number separated by commas. Defaulting to port 80 and continue deploy process.${no_color}" >&2
        PORT_NUM=80
    fi
    # let commas split as well as whitespace
    set -f; IFS=$IFS+","
    for port in $PORT_NUM; do
        if [ "${port}x" != "x" ]; then
            RETVAL="$RETVAL --publish $port"
        fi
    done
    set =f; IFS=$OIFS

    echo $RETVAL
}

###################################################################
# normalize memory size - adjust to the allowed set of memory sizes
###################################################################
get_memory() {
    # make CONT_SIZE all lowercase
    local CONT_SIZE=${1,,}
    local NEW_MEMORY=256
    # check for container size and set the value as MB
    if [ -z "$CONT_SIZE" ] || [ "$CONT_SIZE" == "micro" ] || [ "$CONT_SIZE" == "m1.tiny" ] || [ "$CONT_SIZE" == "256" ];then
        NEW_MEMORY=256
    elif [ "$CONT_SIZE" == "tiny" ] || [ "$CONT_SIZE" == "m1.small" ] || [ "$CONT_SIZE" == "512" ]; then
        NEW_MEMORY=512
    elif [ "$CONT_SIZE" == "small" ] || [ "$CONT_SIZE" == "m1.medium" ] || [ "$CONT_SIZE" == "1024" ]; then
        NEW_MEMORY=1024
    elif [ "$CONT_SIZE" == "medium" ] || [ "$CONT_SIZE" == "m1.large" ] || [ "$CONT_SIZE" == "2048" ]; then
        NEW_MEMORY=2048
    elif [ "$CONT_SIZE" == "large" ] || [ "$CONT_SIZE" == "4096" ]; then
        NEW_MEMORY=4096
    elif [ "$CONT_SIZE" == "x-large" ] || [ "$CONT_SIZE" == "8192" ]; then
        NEW_MEMORY=8192
    elif [ "$CONT_SIZE" == "2x-large" ] || [ "$CONT_SIZE" == "16384" ]; then
        NEW_MEMORY=16384
    elif [ "$CONT_SIZE" == "pico" ] || [ "$CONT_SIZE" == "64" ]; then
        NEW_MEMORY=64
    elif [ "$CONT_SIZE" == "nano" ] || [ "$CONT_SIZE" == "128" ]; then
        NEW_MEMORY=128
    else
        echo -e "${red}$1 is an invalid value, defaulting to micro (256 MB memory) and continuing deploy process.${no_color}" >&2
        NEW_MEMORY=256
    fi
    echo "$NEW_MEMORY"
}

###################################################################
# check_memory_quota
###################################################################
# this function expects a file "iceretry.log" to exist in the current director, being the output of a call to 'ic info'
# example:
#    ic info
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
    if [ "$USE_ICE_CLI" = "1" ]; then
        local MEMORY_LIMIT=$(grep "Memory limit (MB)" iceretry.log | awk '{print $5}')
        local MEMORY_USAGE=$(grep "Memory usage (MB)" iceretry.log | awk '{print $5}')
    else
        local MEMORY_LIMIT=$(grep "Memory limit(MB)" iceretry.log | awk '{print $4}')
        local MEMORY_USAGE=$(grep "Memory usage(MB)" iceretry.log | awk '{print $4}')
    fi
    if [ -z "$MEMORY_LIMIT" ] || [ -z "$MEMORY_USAGE" ]; then
        echo -e "${red}MEMORY_LIMIT or MEMORY_USAGE value is missing from $IC_COMMAND info output command. Defaulting to m1.tiny (256 MB memory) and continuing deploy process.${no_color}" >&2
    else
        if [ $(echo "$MEMORY_LIMIT - $MEMORY_USAGE" | bc) -lt $NEW_MEMORY ]; then
            return 1
        fi
    fi
    return 0
}

###################################################################
# get memory size
###################################################################
get_memory_size() {
    local CONT_SIZE=$1
    local NEW_MEMORY=$(get_memory $CONT_SIZE)
    ice_retry_save_output info >&2
    RESULT=$?
    if [ $RESULT -eq 0 ]; then
        $(check_memory_quota $NEW_MEMORY)
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            echo -e "${red}Quota exceeded for container size: The selected container size $CONT_SIZE exceeded the memory limit. You need to select smaller container size or delete some of your existing containers.${no_color}" | tee -a "$ERROR_LOG_FILE" >&2
            NEW_MEMORY="-1"
        fi
    else
        echo -e "${red}Unable to call $IC_COMMAND info${no_color}" | tee -a "$ERROR_LOG_FILE" >&2 
        NEW_MEMORY="-1"
    fi
    echo "$NEW_MEMORY"
}

###################################################################
# print fail message
###################################################################
print_fail_msg () {
    local TYPE=$1
    log_and_echo ""
    log_and_echo "When a ${TYPE} cannot be created, the following are a common set of debugging steps."
    log_and_echo ""
    if [ "$USE_ICE_CLI" = "1" ]; then
        log_and_echo "1. Install Python, Pip, IBM Container Service CLI (ice), Cloud Foundry CLI, and Docker in your environment."
    else
        log_and_echo "1. Install Docker, Cloud Foundry CLI (cf), and IBM Container plug-in (cf ic),  in your environment."
    fi
    log_and_echo ""
    if [ "$USE_ICE_CLI" = "1" ]; then
        log_and_echo "2. Log into IBM Container Service."                                  
        log_and_echo "      ${green}$IC_COMMAND login ${no_color}"
        log_and_echo "      or" 
        log_and_echo "      ${green}cf login ${no_color}"
    else
        log_and_echo "2. Log into IBM Container Service."                                  
        log_and_echo "      ${green}cf login ${no_color}"
        log_and_echo "      ${green}cf ic init ${no_color}"
    fi
    log_and_echo ""
    if [ "$TYPE" == "ibm_containers" ]; then
        log_and_echo "3. Run '$IC_COMMAND run --verbose' in your current space or try it on another space. Check the output for information about the failure." 
        log_and_echo "      ${green}$IC_COMMAND --verbose run --name ${MY_CONTAINER_NAME} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${IMAGE_NAME} ${no_color}"
    elif [ "${TYPE}" == "ibm_containers_group" ]; then
        log_and_echo "3. Run '$IC_COMMAND group create --verbose' in your current space or try it on another space. Check the output for information about the failure." 
        log_and_echo "      ${green}$IC_COMMAND --verbose group create --name ${MY_GROUP_NAME} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} --desired ${DESIRED_INSTANCES} --max ${MAX_INSTANCES} ${AUTO} ${IMAGE_NAME} ${no_color}"
    fi
    log_and_echo ""
    log_and_echo "4. Test the container locally."
    log_and_echo "  a. Pull the image to your computer."
    log_and_echo "      ${green}docker pull ${IMAGE_NAME} ${no_color}"
    if [ "$USE_ICE_CLI" = "1" ]; then
        log_and_echo "      or" 
        log_and_echo "      ${green}ice --local pull ${IMAGE_NAME} ${no_color}"
    fi
    log_and_echo "  b. Run the container locally by using the Docker run command and allow it to run for several minutes. Verify that the container continues to run. If the container stops, this will cause a crashed container on Bluemix."
    log_and_echo "      ${green}docker run --name=mytestcontainer ${IMAGE_NAME} ${no_color}"
    log_and_echo "      ${green}docker stop mytestcontainer ${no_color}"
    log_and_echo "  c. If you find an issue with the image locally, fix the issue, and then tag and push the image to your registry.  For example: "
    log_and_echo "      [fix and update your local Dockerfile]"
    log_and_echo "      ${green}docker build -t ${IMAGE_NAME%:*}:test . ${no_color}"
    log_and_echo "      ${green}docker push ${IMAGE_NAME%:*}:test ${no_color}"
    if [ "$TYPE" == "ibm_containers" ]; then
        log_and_echo "  d.  Test the changes to the image on Bluemix using the '$IC_COMMAND run' command to determine if the container will now run on Bluemix."
        log_and_echo "      ${green}$IC_COMMAND --verbose run --name ${MY_CONTAINER_NAME}_test ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${IMAGE_NAME%:*}:test ${no_color}"
    elif [ "${TYPE}" == "ibm_containers_group" ]; then
        log_and_echo "  d.  Test the changes to the image on Bluemix using the '$IC_COMMAND group create' command to determine if the container group will now run on Bluemix."
        log_and_echo "      ${green}$IC_COMMAND --verbose group create --name ${MY_GROUP_NAME} ${BIND_PARMS} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} --desired ${DESIRED_INSTANCES} --max ${MAX_INSTANCES} ${AUTO} ${IMAGE_NAME%:*}:test ${no_color}"
    fi
    log_and_echo ""
    log_and_echo "5. Once the problem has been diagnosed and fixed, check in the changes to the Dockerfile and project into your IBM DevOps Services project and re-run this Pipeline."
    log_and_echo ""
    log_and_echo "If the image is working locally, a deployment can still fail for a number of reasons. For more information, see the troubleshooting documentation: ${label_color} https://www.ng.bluemix.net/docs/starters/container_troubleshoot.html ${no_color}."
    log_and_echo ""
}

###################################################################
# dump info
###################################################################
dump_info () {
    log_and_echo "$LABEL" "Container Information: "
    log_and_echo "$LABEL" "Information about this organization and space:"
    log_and_echo "Summary:"
    ice_retry_save_output info 2>/dev/null
    local ICEINFO=$(cat iceretry.log)
    log_and_echo "$ICEINFO"

    # check memory limit, warn user if we're at or approaching the limit
    if [ "$USE_ICE_CLI" = "1" ]; then
        export MEMORY_LIMIT=$(echo "$ICEINFO" | grep "Memory limit" | awk '{print $5}')
    else
        export MEMORY_LIMIT=$(echo "$ICEINFO" | grep "Memory limit" | awk '{print $4}')
    fi
    # if memory limit is disabled no need to check and warn
    if [ ! -z ${MEMORY_LIMIT} ]; then
        if [ ${MEMORY_LIMIT} -ge 0 ]; then
            if [ "$USE_ICE_CLI" = "1" ]; then
                export MEMORY_USAGE=$(echo "$ICEINFO" | grep "Memory usage" | awk '{print $5}')
            else
                export MEMORY_USAGE=$(echo "$ICEINFO" | grep "Memory usage" | awk '{print $4}')
            fi
            local MEM_WARNING_LEVEL="$(echo "$MEMORY_LIMIT - 512" | bc)"

            if [ ${MEMORY_USAGE} -ge ${MEMORY_LIMIT} ]; then
                log_and_echo "$ERROR" "You are using ${MEMORY_USAGE} MB of memory, and may have reached the default limit for memory used "
            elif [ ${MEMORY_USAGE} -ge ${MEM_WARNING_LEVEL} ]; then
                log_and_echo "$WARN" "You are using ${MEMORY_USAGE} MB of memory, which is approaching the limit of ${MEMORY_LIMIT}"
            fi
        fi
    fi

    log_and_echo "$LABEL" "Groups: "
    $IC_COMMAND group list > mylog.log 2>&1 
    cat mylog.log
    log_and_echo "$DEBUGGING" `cat mylog.log`

    log_and_echo "$LABEL" "Routes: "
    cf routes > mylog.log 2>&1 
    cat mylog.log
    log_and_echo "$DEBUGGING" `cat mylog.log`

    log_and_echo "$LABEL" "Running Containers: "
    $IC_COMMAND ps > mylog.log 2>&1 
    cat mylog.log
    log_and_echo "$DEBUGGING" `cat mylog.log`

    log_and_echo "$LABEL" "IP addresses"
    $IC_COMMAND ip list > mylog.log 2>&1 
    cat mylog.log
    log_and_echo "$DEBUGGING" `cat mylog.log`

    log_and_echo "$LABEL" "Images:"
    $IC_COMMAND images > mylog.log 2>&1 
    cat mylog.log
    log_and_echo "$DEBUGGING" `cat mylog.log`

    return 0
}

###################################################################
# update inventory
###################################################################
update_inventory(){
    local TYPE=$1
    local NAME=$2
    local ACTION=$3
    if [ $# -ne 3 ]; then
        log_and_echo "$ERROR" "updating inventory expects a three inputs: 1. type 2. name 3. action. Where type is either group or container, and the name is the name of the container being added to the inventory."
        return 1
    fi
    # find the container or group id
    local ID="undefined"
    local RESULT=0
    if [ "$TYPE" == "ibm_containers" ]; then
        ice_retry_save_output inspect ${NAME} 2> /dev/null
        RESULT=$?
        if [ $RESULT -eq 0 ]; then
            ID=$(grep "\"Id\":" iceretry.log | awk '{print $2}')
            if [ -z "${ID}" ]; then
                log_and_echo "$ERROR" "Could not find container called $NAME"
                $IC_COMMAND ps 2> /dev/null
                return 1
            fi
        else
            log_and_echo "$ERROR" "$IC_COMMAND inspect ${NAME} failed"
            return 1
        fi               
    elif [ "${TYPE}" == "ibm_containers_group" ]; then
        ice_retry_save_output group inspect ${NAME} 2> /dev/null
        RESULT=$?
        if [ $RESULT -eq 0 ]; then
            ID=$(grep "\"Id\":" iceretry.log | awk '{print $2}')
            if [ -z "${ID}" ]; then
                log_and_echo "$ERROR" "Could not find group called $NAME"
                $IC_COMMAND group list 2> /dev/null
                return 1
            fi
        else
            log_and_echo "$ERROR" "$IC_COMMAND group inspect ${NAME} failed"
            return 1
        fi        
    else
        log_and_echo "$ERROR" "Could not update inventory with unknown type: ${TYPE}"
        return 1
    fi

    local JOB_TYPE=""
    # trim off junk
    local temp="${ID%\",}"
    ID="${temp#\"}"
    log_and_echo "The ID of the $TYPE is: $ID"

    # find other inventory information
    log_and_echo "$LABEL" "Updating inventory with $TYPE of $NAME "
    local IDS_INV_URL="${IDS_URL%/}"
    local IDS_REQUEST=$TASK_ID
    local IDS_DEPLOYER=${JOB_NAME##*/}
    if [ ! -z "$COPYARTIFACT_BUILD_NUMBER" ] ; then
        IDS_VERSION_TYPE="JENKINS_BUILD_ID"
        IDS_VERSION=$COPYARTIFACT_BUILD_NUMBER
    elif [ ! -z "$CS_BUILD_SELECTOR" ] ; then
        IDS_VERSION_TYPE="JENKINS_BUILD_ID"
        IDS_VERSION=$CS_BUILD_SELECTOR
    else
            IDS_VERSION_TYPE="SCM_REV_ID"
        if [ ! -z "$GIT_COMMIT" ] ; then
            IDS_VERSION=$GIT_COMMIT
        elif [ ! -z "$RTCBuildResultUUID" ] ; then
            IDS_VERSION=$RTCBuildResultUUID
        fi
    fi

    if [ -z "$IDS_RESOURCE" ]; then
        local IDS_RESOURCE="https://hub.jazz.net/pipeline"
    fi

    if [ -z "$IDS_VERSION" ]; then
        local IDS_RESOURCE="1"
    fi

    IDS_RESOURCE=$CF_SPACE_ID
    if [ -z "$IDS_RESOURCE" ]; then
        log_and_echo "$ERROR" "Could not find CF SPACE in environment, using production space id"
    else
        # call IBM DevOps Service Inventory CLI to update the entry for this deployment
        log_and_echo "bash ids-inv -a ${ACTION} -d $IDS_DEPLOYER -q $IDS_REQUEST -r $IDS_RESOURCE -s $ID -t ${TYPE} -u $IDS_INV_URL -v $IDS_VERSION"
        bash ids-inv -a ${ACTION} -d $IDS_DEPLOYER -q $IDS_REQUEST -r $IDS_RESOURCE -s $ID -t ${TYPE} -u $IDS_INV_URL -v $IDS_VERSION
    fi
}

###################################################################
# check_image
###################################################################
check_image() {
    local NAME=$1
    if [ -z ${NAME} ]; then
        log_and_echo "$INFO" "Expected image name to be passed into check_image"
        return 0
    fi
    ice_retry_save_output images
    local RC=$?
    if [ $RC -eq 0 ]; then
        if [ "$USE_ICE_CLI" = "1" ]; then
            grep ${NAME} iceretry.log >/dev/null
            RC=$?
            if [ $RC -eq 0 ]; then
                return 0
            else
                return 1
            fi
        else
            local IMAGE_NAME=$(cut -d : -f 1 <<< $NAME)
            local IMAGE_VERSION=$(cut -d : -f 2 <<< $NAME)
            local VERSION_LIST=$(grep ${IMAGE_NAME} iceretry.log | awk '{print $2}')
            RC=$?
            if [ $RC -ne 0 ] || [ -z "${VERSION_LIST}" ]; then
                return 1
            else
                for VER in ${VERSION_LIST[@]} 
                do 
                    if [ $VER -eq $IMAGE_VERSION ]; then 
                        return 0
                    fi
                done  
    	        return 1
            fi
        fi
    else
        log_and_echo "$ERROR" "'cf ic images' command failed with return code ${RESULT}"
        return 1
    fi
}

export -f check_image

###################################################################
# Unit Test
###################################################################
# internal function, selfcheck unit test to make sure things are working
# as expected
unittest() {
    local RET=0

    # Unit Test for get_memory() function
    #############################################
    RET=$(get_memory 64 2> /dev/null)
    if [ "${RET}x" != "64x" ]; then
        echo "ut fail (bad memory value on check 64)"
        return 10
    fi
    RET=$(get_memory "pico" 2> /dev/null)
    if [ "${RET}x" != "64x" ]; then
        echo "ut fail (bad memory value on check pico)"
        return 11
    fi
    RET=$(get_memory 128 2> /dev/null)
    if [ "${RET}x" != "128x" ]; then
        echo "ut fail (bad memory value on check 128)"
        return 12
    fi
    RET=$(get_memory "nano" 2> /dev/null)
    if [ "${RET}x" != "128x" ]; then
        echo "ut fail (bad memory value on check nano)"
        return 13
    fi
    RET=$(get_memory 256 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check 256)"
        return 14
    fi
    RET=$(get_memory "m1.tiny" 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check m1.tiny)"
        return 15
    fi
    RET=$(get_memory "micro" 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check micro)"
        return 16
    fi
    RET=$(get_memory 512 2> /dev/null)
    if [ "${RET}x" != "512x" ]; then
        echo "ut fail (bad memory value on check 512)"
        return 17
    fi
    RET=$(get_memory "m1.small" 2> /dev/null)
    if [ "${RET}x" != "512x" ]; then
        echo "ut fail (bad memory value on check m1.small)"
        return 18
    fi
    RET=$(get_memory "tiny" 2> /dev/null)
    if [ "${RET}x" != "512x" ]; then
        echo "ut fail (bad memory value on check tiny)"
        return 19
    fi
    RET=$(get_memory 1024 2> /dev/null)
    if [ "${RET}x" != "1024x" ]; then
        echo "ut fail (bad memory value on check 1024)"
        return 20
    fi
    RET=$(get_memory "small" 2> /dev/null)
    if [ "${RET}x" != "1024x" ]; then
        echo "ut fail (bad memory value on check small)"
        return 21
    fi
    RET=$(get_memory "m1.medium" 2> /dev/null)
    if [ "${RET}x" != "1024x" ]; then
        echo "ut fail (bad memory value on check m1.medium)"
        return 22
    fi
    RET=$(get_memory 2048 2> /dev/null)
    if [ "${RET}x" != "2048x" ]; then
        echo "ut fail (bad memory value on check 2048)"
        return 23
    fi
    RET=$(get_memory "medium" 2> /dev/null)
    if [ "${RET}x" != "2048x" ]; then
        echo "ut fail (bad memory value on check medium)"
        return 24
    fi
    RET=$(get_memory "m1.large" 2> /dev/null)
    if [ "${RET}x" != "2048x" ]; then
        echo "ut fail (bad memory value on check m1.large)"
        return 25
    fi
    RET=$(get_memory 4096 2> /dev/null)
    if [ "${RET}x" != "4096x" ]; then
        echo "ut fail (bad memory value on check 4096)"
        return 26
    fi
    RET=$(get_memory "large" 2> /dev/null)
    if [ "${RET}x" != "4096x" ]; then
        echo "ut fail (bad memory value on check large)"
        return 27
    fi
    RET=$(get_memory 8192 2> /dev/null)
    if [ "${RET}x" != "8192x" ]; then
        echo "ut fail (bad memory value on check 8192)"
        return 28
    fi
    RET=$(get_memory "x-large" 2> /dev/null)
    if [ "${RET}x" != "8192x" ]; then
        echo "ut fail (bad memory value on check x-large)"
        return 29
    fi
    RET=$(get_memory 16384 2> /dev/null)
    if [ "${RET}x" != "16384x" ]; then
        echo "ut fail (bad memory value on check 16384)"
        return 30
    fi
    RET=$(get_memory "2x-large" 2> /dev/null)
    if [ "${RET}x" != "16384x" ]; then
        echo "ut fail (bad memory value on check 2x-large)"
        return 31
    fi
    RET=$(get_memory 32 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check 32)"
        return 32
    fi
    RET=$(get_memory "bad_value" 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check bad_value)"
        return 33
    fi
    RET=$(get_memory 1 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on check 1)"
        return 34
    fi
    RET=$(get_memory "" 2> /dev/null)
    if [ "${RET}x" != "256x" ]; then
        echo "ut fail (bad memory value on empty check)"
        return 35
    fi

    # Unit Test for check_memory_quota() function
    #############################################
    echo "Memory limit (MB)      : 2048" >iceretry.log
    echo "Memory usage (MB)      : 0" >>iceretry.log
    $(check_memory_quota 256 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "ut fail (bad quota check with 256 size)"
        return 40
    fi

    echo "Memory limit (MB)      : 2048" >iceretry.log
    echo "Memory usage (MB)      : 1024" >>iceretry.log
    $(check_memory_quota 2048 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 1 ]; then
        echo "ut fail (incorrect pass for too much memory 2048+2048)"
        return 41
    fi

    echo "Memory limit (MB)      : 2048" >iceretry.log
    echo "Memory usage (MB)      : 2048" >>iceretry.log
    $(check_memory_quota 512 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 1 ]; then
        echo "ut fail (incorrect pass for too much memory 2048+512)"
        return 42
    fi
    echo "Memory limit (MB)      : 1024" >iceretry.log
    echo "Memory usage (MB)      : 0" >>iceretry.log
    $(check_memory_quota 512 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "ut fail (bad quota check with 512 size)"
        return 43
    fi

    echo "Memory limit (MB)      : 2048" >iceretry.log
    echo "Memory usage (MB)      : 1024" >>iceretry.log
    $(check_memory_quota -1 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 0 ]; then
        echo "ut fail (bad quota check with -1 size)"
        return 44
    fi

    echo "Memory limit (MB)      : 2048" >iceretry.log
    echo "Memory usage (MB)      : 2048" >>iceretry.log
    $(check_memory_quota -1 2> /dev/null)
    RET=$?
    if [ ${RET} -ne 1 ]; then
        echo "incorrect pass for too much memory 2048+\"-1\")"
        return 45
    fi

    # Unit Test for get_port_numbers() function
    #############################################
    RET=$(get_port_numbers "80" 2> /dev/null)
    if [ "${RET}x" != "--publish 80x" ]; then
        echo "ut fail (bad publish value on port check \"80\")"
        return 50
    fi
    RET=$(get_port_numbers "80,8080" 2> /dev/null)
    if [ "${RET}x" != "--publish 80 --publish 8080x" ]; then
        echo "ut fail (bad publish value on port check \"80,8080\")"
        return 51
    fi
    RET=$(get_port_numbers "80,8080 " 2> /dev/null)
    if [ "${RET}x" != "--publish 80 --publish 8080x" ]; then
        echo "ut fail (bad error check on trailing space \"80, 8080 \")"
        return 52
    fi
    RET=$(get_port_numbers "80,8080 ," 2> /dev/null)
    if [ "${RET}x" != "--publish 80 --publish 8080x" ]; then
        echo "ut fail (bad error check on trailing space and comma \"80, 8080 ,\")"
        return 53
    fi
    RET=$(get_port_numbers "80, 8080" 2> /dev/null)
    if [ "${RET}x" != "--publish 80 --publish 8080x" ]; then
        echo "ut fail (bad error check on intervening space \"80, 8080\")"
        return 54
    fi
    RET=$(get_port_numbers "badvalue" 2> /dev/null)
    if [ "${RET}x" != "--publish 80x" ]; then
        echo "ut fail (bad error check on invalid value)"
        return 55
    fi
    RET=$(get_port_numbers "80,,,,8080" 2> /dev/null)
    if [ "${RET}x" != "--publish 80 --publish 8080x" ]; then
        echo "ut fail (bad filtering on internal commas)"
        return 56
    fi
    RET=$(get_port_numbers ",,,,80,8080" 2> /dev/null)
    if [ "${RET}x" != "--publish 80 --publish 8080x" ]; then
        echo "ut fail (bad filtering on leading commas)"
        return 57
    fi
    RET=$(get_port_numbers "80,8080,,,," 2> /dev/null)
    if [ "${RET}x" != "--publish 80 --publish 8080x" ]; then
        echo "ut fail (bad filtering on trailing commas)"
        return 58
    fi
    RET=$(get_port_numbers "80    8080" 2> /dev/null)
    if [ "${RET}x" != "--publish 80 --publish 8080x" ]; then
        echo "ut fail (bad check on no commas)"
        return 59
    fi

    return 0
}

# Unit test for the memory size
unittest
UTRC=$?
if [ $UTRC -ne 0 ]; then
    echo "Unit test failed, aborting with return code $UTRC"
else
    # allow run the script with --get_memory parameter to check get_memory with custom parms directly
    FTTCMD=$1
    if [ ! -z $FTTCMD ]; then
        if [ "$FTTCMD" == "--get_memory" ]; then
            FTTCMD="get_memory"
        elif [ "$FTTCMD" == "--check_memory_quota" ]; then
            FTTCMD="check_memory_quota"
        elif [ "$FTTCMD" == "--get_port_numbers" ]; then
            FTTCMD="get_port_numbers"
        else
            FTTCMD=""
        fi

        if [ "${FTTCMD}x" != "x" ]; then
            shift
            rc=0
            for i in $@
            do
                COMMAND="$FTTCMD $i"
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
fi

