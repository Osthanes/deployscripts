#!/bin/bash

#********************************************************************************
# Copyright 2014 IBM
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
#********************************************************************************

# load helper functions
source $(dirname "$0")/deploy_utilities.sh

insert_inventory(){
    update_inventory $1 $2 "insert"
}
delete_inventory(){
    update_inventory $1 $2 "delete"
}

# function to wait for a container to start
# takes a container name as the only parameter
wait_for (){
    local WAITING_FOR=$1
    if [ -z ${WAITING_FOR} ]; then
        log_and_echo "$ERROR" "Expected container name to be passed into wait_for"
        return 1
    fi
    local COUNTER=0
    local STATE="unknown"
    while [[ ( $COUNTER -lt 180 ) && ("${STATE}" != "Running") && ("${STATE}" != "Crashed") ]]; do
        let COUNTER=COUNTER+1
        STATE=$($IC_COMMAND inspect $WAITING_FOR 2> /dev/null | grep "Status" | awk '{print $2}' | sed 's/"//g')
        if [ -z "${STATE}" ]; then
            STATE="being placed"
        fi
        log_and_echo "${WAITING_FOR} is ${STATE}"
        sleep 3
    done
    if [ "$STATE" == "Crashed" ]; then
        return 2
    fi
    if [ "$STATE" != "Running" ]; then
        log_and_echo "$ERROR" "Failed to start instance "
        return 1
    fi
    return 0
}

# function to wait for a container to start
# takes a container name as the only parameter
wait_for_stopped (){
    local WAITING_FOR=$1
    if [ -z ${WAITING_FOR} ]; then
        log_and_echo "$ERROR" "Expected container name to be passed into wait_for"
        return 1
    fi
    local COUNTER=0
    local FOUND=0
    while [[ ( $COUNTER -lt 60 ) && ("${STATE}" != "Shutdown")  ]]; do
        let COUNTER=COUNTER+1
        STATE=$($IC_COMMAND inspect $WAITING_FOR 2> /dev/null | grep "Status" | awk '{print $2}' | sed 's/"//g')
        if [ -z "${STATE}" ]; then
            STATE="being deleted"
        fi
        sleep 2
    done
    if [ "$STATE" != "Shutdown" ]; then
        log_and_echo "$ERROR" "Failed to stop instance $WAITING_FOR "
        return 1
    else
        log_and_echo "Successfully stopped $WAITING_FOR"
    fi
    return 0
}

deploy_container() {
    local MY_CONTAINER_NAME=$1
    log_and_echo "deploying container ${MY_CONTAINER_NAME}"

    if [ -z MY_CONTAINER_NAME ];then
        log_and_echo "$ERROR" "No container name was provided"
        return 1
    fi

    # check to see if that container name is already in use
    $IC_COMMAND inspect ${MY_CONTAINER_NAME} > /dev/null
    local FOUND=$?
    if [ ${FOUND} -eq 0 ]; then
        log_and_echo "$ERROR" "${MY_CONTAINER_NAME} already exists.  Please remove these containers or change the Name of the container or group being deployed"
    fi

    # check to see if container image is exisit 
    check_image "$IMAGE_NAME"
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Image '${IMAGE_NAME}' does not exist."
        $IC_COMMAND images
        return 1
    fi

    local BIND_PARMS=""
    # validate the bind_to parameter if one was passed
    if [ ! -z "${BIND_TO}" ]; then
        log_and_echo "Binding to ${BIND_TO}"
        local APP=$(cf env ${BIND_TO})
        local APP_FOUND=$?
        if [ $APP_FOUND -ne 0 ]; then
            log_and_echo "$ERROR" "${BIND_TO} application not found in space.  Please confirm that you wish to bind the container to the application, and that the application exists"
        fi
        local VCAP_SERVICES=$(echo "${APP}" | grep "VCAP_SERVICES")
        local SERVICES_BOUND=$?
        if [ $SERVICES_BOUND -ne 0 ]; then
            log_and_echo "$WARN" "No services appear to be bound to ${BIND_TO}.  Please confirm that you have bound the intended services to the application."
        fi
        if [ "$USE_ICE_CLI" = "1" ]; then
            BIND_PARMS="--bind ${BIND_TO}"
        else
            BIND_PARMS="-e CCS_BIND_APP=${BIND_TO}"
        fi
    fi
    # run the container and check the results
    log_and_echo "run the container: $IC_COMMAND run --name ${MY_CONTAINER_NAME} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${IMAGE_NAME} "
    ice_retry run --name ${MY_CONTAINER_NAME} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${IMAGE_NAME} 2> /dev/null
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Failed to deploy ${MY_CONTAINER_NAME} using ${IMAGE_NAME}"
        dump_info
        return 1
    fi

    # wait for container to start
    wait_for ${MY_CONTAINER_NAME}
    RESULT=$?
    if [ $RESULT -eq 0 ]; then
        insert_inventory "ibm_containers" ${MY_CONTAINER_NAME}
    elif [ $RESULT -eq 2 ]; then
        log_and_echo "$ERROR" "Container instance crashed."
        log_and_echo "$WARN" "The container was removed successfully."
        ice_retry rm ${MY_CONTAINER_NAME} 2> /dev/null
        if [ $? -ne 0 ]; then
            log_and_echo "$WARN" "'$IC_COMMAND rm ${MY_CONTAINER_NAME}' command failed with return code ${RESULT}"
            log_and_echo "$WARN" "Removing Container instance ${MY_CONTAINER_NAME} is not completed"
        fi
        print_fail_msg "ibm_containers"
    fi
    return ${RESULT}
}

deploy_simple () {
    local MY_CONTAINER_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    deploy_container ${MY_CONTAINER_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Error encountered with simple build strategy for ${CONTAINER_NAME}_${BUILD_NUMBER}"
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed deployment of ${MY_CONTAINER_NAME}. $(get_error_info)"
        exit $RESULT
    fi
}

deploy_red_black () {
    log_and_echo "$LABEL" "Example red_black container deploy "
    # deploy new version of the application
    local MY_CONTAINER_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    local FLOATING_IP=""
    local IP_JUST_FOUND=""
    deploy_container ${MY_CONTAINER_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed deployment of ${MY_CONTAINER_NAME}. $(get_error_info)"
        exit $RESULT
    fi

    # Cleaning up previous deployments. "
    clean
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed to cleanup previous deployments after deployment of ${MY_CONTAINER_NAME}. $(get_error_info)"
        exit $RESULT
    fi
    # if we alredy discoved the floating IP in clean(), then we assign it to FLOATING_IP.
    if [ -n "${DISCOVERED_FLOATING_IP}" ]; then
        FLOATING_IP=$DISCOVERED_FLOATING_IP
    fi

    # check to see that I obtained a floating IP address
    #ice inspect ${CONTAINER_NAME}_${BUILD_NUMBER} > inspect.log
    #FLOATING_IP=$(cat inspect.log | grep "PublicIpAddress" | awk '{print $2}')
    if [ "${FLOATING_IP}" = '""' ] || [ -z "${FLOATING_IP}" ]; then
        log_and_echo "Check for the free IP, will attempt to reuse existing IP"
        ice_retry_save_output ip list 2> /dev/null
        FLOATING_IP=$(grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}[[:space:]]*$' iceretry.log | head -n 1)
        #strip off whitespace
        FLOATING_IP=${FLOATING_IP// /}
        if [ -z "${FLOATING_IP}" ];then
            log_and_echo "No any free IP address found. Requesting new IP"
            ice_retry_save_output ip request 2> /dev/null
            if [ "$USE_ICE_CLI" = "1" ]; then
                FLOATING_IP=$(awk '{print $4}' iceretry.log | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
            else
                FLOATING_IP=$(awk '{print $3}' iceretry.log | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
            fi
            RESULT=$?
            if [ $RESULT -ne 0 ]; then
                cat iceretry.log
                log_and_echo "$ERROR" "Could not request a new, or reuse an existing IP address "
                dump_info
                ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed deployment of ${MY_CONTAINER_NAME}.  Unable to allocate IP address. $(get_error_info)"
                exit 1
            else
                # strip off junk
                temp="${FLOATING_IP%\"}"
                FLOATING_IP="${temp#\"}"
                log_and_echo "Assign new IP address $FLOATING_IP"
            fi
        else
            log_and_echo "Reuse an existing IP address $FLOATING_IP"
        fi
        ice_retry ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            cat iceretry.log
            log_and_echo "$ERROR" "Failed to bind ${FLOATING_IP} to ${CONTAINER_NAME}_${BUILD_NUMBER} "
            log_and_echo "Unsetting TEST_URL"
            export TEST_URL=""
            dump_info
            ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed binding of IP address to ${MY_CONTAINER_NAME}. $(get_error_info)"
            exit 1
        fi
    fi
    TEST_URL="${URL_PROTOCOL}${FLOATING_IP}:$(echo $PORT | sed 's/,/ /g' |  awk '{print $1;}')"
    log_and_echo "Exporting TEST_URL:${TEST_URL}"
    if [ ! -z ${DEPLOY_PROPERTY_FILE} ]; then
        echo "export TEST_URL="${TEST_URL}"" >> "${DEPLOY_PROPERTY_FILE}"
        echo "export TEST_IP="${FLOATING_IP}"" >> "${DEPLOY_PROPERTY_FILE}"
        echo "export TEST_PORT="$(echo $PORT | sed 's/,/ /g' |  awk '{print $1;}')"" >> "${DEPLOY_PROPERTY_FILE}"
    fi
 
    log_and_echo "${green}Public IP address of ${CONTAINER_NAME}_${BUILD_NUMBER} is ${FLOATING_IP} and the TEST_URL is ${TEST_URL} ${no_color}"
}

clean() {
    log_and_echo "Cleaning up previous deployments.  Will keep ${CONCURRENT_VERSIONS} versions active."
    local RESULT=0
    local FIND_PREVIOUS="false"
    local FLOATING_IP=""
    local IP_JUST_FOUND=""
    local NEW_DISCOVERED_IP=""
    local containerName=""
    if [ "$USE_ICE_CLI" != "1" ]; then
        # if the IC_COMMAND is cf ic, then it need to use discovered public IP address
        log_and_echo "Check if it is already discovered a PublicIpAddress during run container ${CONTAINER_NAME}_${BUILD_NUMBER}"
        sleep 10
        ice_retry_save_output inspect ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
        RESULT=$?
        if [ $RESULT -eq 0 ]; then
            local FOUND_FLOATING_IP=$(grep "PublicIpAddress" iceretry.log | awk '{print $2}')
            temp="${FOUND_FLOATING_IP%\"}"
            FOUND_FLOATING_IP="${temp#\"}"
            if [ -n "${FOUND_FLOATING_IP}" ]; then
                NEW_DISCOVERED_IP=${FOUND_FLOATING_IP}
                log_and_echo "New iscovered ip is ${NEW_DISCOVERED_IP}"
            else
                log_and_echo "$WARN" "no any PublicIpAddress discovered for ${CONTAINER_NAME}_${BUILD_NUMBER}"
            fi
        else
           log_and_echo "$WARN" "'$IC_COMMAND inspect ${CONTAINER_NAME}_${BUILD_NUMBER}' command failed with return code ${RESULT}" 
           log_and_echo "$DEBUGGING" `cat iceretry.log`
        fi
    fi
    # if we have a requested floating ip, try to use that one instead of any other
    if [ -n "${REQUESTED_FLOATING_IP}" ]; then
        # make sure we own this ip
        ice_retry_save_output ip list 2> /dev/null
        RESULT=$?
        if [ $RESULT -ne 0 ]; then 
            log_and_echo "$ERROR" "'$IC_COMMAND ip list' command failed with return code ${RESULT}"
            log_and_echo "$ERROR" "The requested ip will not be used"
        else
            local find_requested_ip=$(grep "\<${REQUESTED_FLOATING_IP}\>" iceretry.log)
            if [ -z "${find_requested_ip}" ]; then
                log_and_echo "$ERROR" "Requested ip ${REQUESTED_FLOATING_IP} is not assigned to this org and space and cannot be used."
            else
                # is it already in use
                local old_bound_container=$(echo "${find_requested_ip}" | awk '{print $2}')
                if [ -n "${old_bound_container}" ]; then
                    # unbind it from the old one first
                    ice_retry ip unbind ${REQUESTED_FLOATING_IP} ${old_bound_container} 2> /dev/null
                    RESULT=$?
                    if [ $RESULT -ne 0 ]; then
                        log_and_echo "$ERROR" "'$IC_COMMAND ip unbind ${REQUESTED_FLOATING_IP} ${old_bound_container}' command failed with return code ${RESULT}"
                    else
                        log_and_echo "Requested ip ${REQUESTED_FLOATING_IP} was successfully unbound from previous container ${old_bound_container}"
                    fi
                    # sleep to let it take effect
                    sleep 2
                fi
                if [ "$USE_ICE_CLI" != "1" ] && [ -n "${NEW_DISCOVERED_IP}" ]; then
                    ice_retry ip release ${NEW_DISCOVERED_IP} 2> /dev/null
                    RESULT=$?
                    if [ $RESULT -eq 0 ]; then
                        log_and_echo "The new discovered ip ${NEW_DISCOVERED_IP} was successfully release"
                    else
                        log_and_echo "$ERROR" "'$IC_COMMAND ip release ${NEW_DISCOVERED_IP}' command failed with return code ${RESULT}"
                    fi
                    sleep 2
                fi
                # bind it to our new container
                ice_retry ip bind ${REQUESTED_FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
                RESULT=$?
                if [ $RESULT -ne 0 ]; then
                    log_and_echo "$ERROR" "'$IC_COMMAND ip bind ${REQUESTED_FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER}' command failed with return code ${RESULT}"
                else
                    # save that it worked, so we don't try to reclaim a different one
                    FLOATING_IP=${REQUESTED_FLOATING_IP}
                    log_and_echo "Requested ip ${FLOATING_IP} was successfully bound to ${CONTAINER_NAME}_${BUILD_NUMBER}"
                fi
            fi
        fi
    fi
    # add the container name that need to keep in an array
    for (( i = 0 ; i < $CONCURRENT_VERSIONS ; i++ ))
    do
        KEEP_BUILD_NUMBERS[$i]="${CONTAINER_NAME}_$(($BUILD_NUMBER-$i))"
    done
    # add the current containers in an array of the container name
    if [ "$USE_ICE_CLI" = "1" ]; then
        ice_retry_save_output ps -q 2> /dev/null
    else
        ice_retry_save_output ps 2> /dev/null
    fi   
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$WARN" "'$IC_COMMAND ps -q' command failed with return code ${RESULT}"
        log_and_echo "$DEBUGGING" `cat iceretry.log`
        log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
        return 0
    else
        if [ "$USE_ICE_CLI" = "1" ]; then
            local CONTAINER_NAME_ARRAY=$(grep ${CONTAINER_NAME} iceretry.log | awk '{print $2}')
        else
            local CONTAINER_NAME_ARRAY=$(grep -oh -e "${CONTAINER_NAME}_[0-9]\+" iceretry.log)
        fi   
    fi
    # loop through the array of the container name and check which one it need to keep
    for containerName in ${CONTAINER_NAME_ARRAY[@]}
    do
        CONTAINER_VERSION_NUMBER=$(echo $containerName | sed 's#.*_##g')
        if [ $CONTAINER_VERSION_NUMBER -le $BUILD_NUMBER ]; then
            ice_retry_save_output inspect ${containerName} 2> /dev/null
            RESULT=$?
            if [ $RESULT -eq 0 ]; then
                log_and_echo "Found container ${containerName}"
                # does it have a public IP address
                if [ -z "${FLOATING_IP}" ]; then
                    FLOATING_IP=$(grep "PublicIpAddress" iceretry.log | awk '{print $2}')
                    temp="${FLOATING_IP%\"}"
                    FLOATING_IP="${temp#\"}"
                    if [ -n "${FLOATING_IP}" ]; then
                       log_and_echo "Discovered previous IP ${FLOATING_IP}"
                       IP_JUST_FOUND=$FLOATING_IP
                    fi
                else
                    log_and_echo "Did not search for previous IP because we have already discovered $FLOATING_IP"
                fi
            fi
            if [[ "$containerName" != *"$BUILD_NUMBER"* ]]; then
                # this is a previous deployment
                if [ -z "${FLOATING_IP}" ]; then
                    log_and_echo "${containerName} did not have a floating IP so will need to discover one from previous deployment or allocate one"
                elif [ -n "${IP_JUST_FOUND}" ]; then
                    log_and_echo "${containerName} had a floating ip ${FLOATING_IP}"
                    ice_retry ip unbind ${FLOATING_IP} ${containerName} 2> /dev/null
                    RESULT=$?
                    if [ $RESULT -ne 0 ]; then
                        log_and_echo "$WARN" "'$IC_COMMAND ip unbind ${FLOATING_IP} ${containerName}' command failed with return code ${RESULT}"
                        log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
                        return 0
                    fi   
                    sleep 2                    
                    if [ "$USE_ICE_CLI" != "1" ] && [ -n "${NEW_DISCOVERED_IP}" ]; then
                        ice_retry ip release ${NEW_DISCOVERED_IP} 2> /dev/null
                        RESULT=$?
                        if [ $RESULT -eq 0 ]; then
                            log_and_echo "The new discovered ip ${NEW_DISCOVERED_IP} was successfully release"
                        else
                            log_and_echo "$ERROR" "'$IC_COMMAND ip release ${NEW_DISCOVERED_IP}' command failed with return code ${RESULT}"
                        fi
                        sleep 2
                    fi
                    fi
                    ice_retry ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
                    RESULT=$?
                    if [ $RESULT -ne 0 ]; then
                        log_and_echo "$WARN" "'$IC_COMMAND ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER}' command failed with return code ${RESULT}"
                        log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
                        return 0
                    fi
                fi
            fi
        fi
        if [ $CONTAINER_VERSION_NUMBER -gt $BUILD_NUMBER ]; then
            log_and_echo "$WARN" "The container ${containerName} version is greater then the current build number ${BUILD_NUMBER} and it will not be removed."
            log_and_echo "$WARN" "You may remove it with the $IC_COMMAND cli command '$IC_COMMAND rm -f ${containerName}'"
        elif [[ " ${KEEP_BUILD_NUMBERS[*]} " == *" ${containerName} "* ]]; then
            # this is the concurrent version so keep it around
            log_and_echo "keeping deployment: ${containerName}"
        else
            log_and_echo "delete inventory: ${containerName}"
            delete_inventory "ibm_containers" ${containerName}
            log_and_echo "removing previous deployment: ${containerName}"
            ice_retry rm -f ${containerName} 2> /dev/null
            RESULT=$?
            if [ $RESULT -ne 0 ]; then
                log_and_echo "$WARN" "'$IC_COMMAND rm -f ${containerName}' command failed with return code ${RESULT}"
                log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
                return 0
            fi
            FIND_PREVIOUS="true"
        fi
        IP_JUST_FOUND=""
    done
    if [ FIND_PREVIOUS="false" ]; then
        if [ "$USE_ICE_CLI" != "1" ] && [ -n "${NEW_DISCOVERED_IP}" ]; then
            FLOATING_IP=$NEW_DISCOVERED_IP
        fi
        log_and_echo "No previous deployments found to clean up"
    else
        log_and_echo "Cleaned up previous deployments"
    fi
    if [ -n "${FLOATING_IP}" ]; then
       log_and_echo "Discovered previous IP ${FLOATING_IP}"
       export DISCOVERED_FLOATING_IP=$FLOATING_IP
    else
       export DISCOVERED_FLOATING_IP=""
    fi
    return 0
}
##################
# Initialization #
##################
# Check to see what deployment type:
#   simple: simply deploy a container and set the inventory
#   red_black: deploy new container, assign floating IP address, keep original container
if [ -z "$URL_PROTOCOL" ]; then
 export URL_PROTOCOL="http://"
fi

# set the port numbers with --publish
if [ -z "$PORT" ]; then
    export PUBLISH_PORT="--publish 80"
else
    export PUBLISH_PORT=$(get_port_numbers "${PORT}")
fi

if [ ! -z ${DEPLOY_PROPERTY_FILE} ]; then
    echo "export SINGLE_CONTAINER_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"" >> "${DEPLOY_PROPERTY_FILE}"
fi

# set the memory size
if [ -z "$CONTAINER_SIZE" ];then
    export MEMORY=""
else
    RET_MEMORY=$(get_memory_size $CONTAINER_SIZE)
    if [ $RET_MEMORY == -1 ]; then
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed with container size ${CONTAINER_SIZE}. $(get_error_info)"
        exit 1;
    else
        export MEMORY="--memory $RET_MEMORY"
    fi
fi

# set current version
if [ -z "$CONCURRENT_VERSIONS" ];then
    export CONCURRENT_VERSIONS=1
fi

log_and_echo "$LABEL" "Deploying using ${DEPLOY_TYPE} strategy, for ${CONTAINER_NAME}, deploy number ${BUILD_NUMBER}"
${EXT_DIR}/utilities/sendMessage.sh -l info -m "New ${DEPLOY_TYPE} container deployment for ${CONTAINER_NAME} requested"

if [ "${DEPLOY_TYPE}" == "red_black" ]; then
    deploy_red_black
elif [ "${DEPLOY_TYPE}" == "clean" ]; then
    clean
else
    log_and_echo "$WARN" "Currently only supporting red_black deployment strategy"
    log_and_echo "$WARN" "If you would like another strategy please fork https://github.com/Osthanes/deployscripts.git and submit a pull request"
    log_and_echo "$WARN" "Defaulting to red_black deploy"
    deploy_red_black
fi
dump_info
${EXT_DIR}/utilities/sendMessage.sh -l good -m "Sucessful deployment of ${CONTAINER_NAME}"
exit 0
