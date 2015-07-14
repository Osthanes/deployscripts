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

print_run_fail_msg () {
    log_and_echo ""
    log_and_echo "When a container cannot be created, the following are a common set of debugging steps."
    log_and_echo ""
    log_and_echo "1. Install Python, Pip, IBM Container Service CLI (ice), Cloud Foundry CLI, and Docker in your environment."
    log_and_echo ""
    log_and_echo "2. Log into IBM Container Service."                                  
    log_and_echo "      ${green}ice login ${no_color}"
    log_and_echo "      or" 
    log_and_echo "      ${green}cf login ${no_color}"
    log_and_echo ""
    log_and_echo "2. Run 'ice run --verbose' in your current space or try it on another space. Check the output for information about the failure." 
    log_and_echo "      ${green}ice --verbose run --name ${MY_CONTAINER_NAME} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${IMAGE_NAME} ${no_color}"
    log_and_echo ""
    log_and_echo "3. Test the container locally."
    log_and_echo "  a. Pull the image to your computer."
    log_and_echo "      ${green}docker pull ${IMAGE_NAME} ${no_color}"
    log_and_echo "      or" 
    log_and_echo "      ${green}ice --local pull ${IMAGE_NAME} ${no_color}"
    log_and_echo "  b. Run the container locally by using the Docker run command and allow it to run for several minutes. Verify that the container continues to run. If the container stops, this will cause a crashed container on Bluemix."
    log_and_echo "      ${green}docker run --name=mytestcontainer ${IMAGE_NAME} ${no_color}"
    log_and_echo "      ${green}docker stop mytestcontainer ${no_color}"
    log_and_echo "  c. If you find an issue with the image locally, fix the issue, and then tag and push the image to your registry.  For example: "
    log_and_echo "      [fix and update your local Dockerfile]"
    log_and_echo "      ${green}docker build -t ${IMAGE_NAME%:*}:test . ${no_color}"
    log_and_echo "      ${green}docker push ${IMAGE_NAME%:*}:test ${no_color}"
    log_and_echo "  d.  Test the changes to the image on Bluemix using the 'ice run' command to determine if the container will now run on Bluemix."
    log_and_echo "      ${green}ice --verbose run --name ${MY_CONTAINER_NAME}_test ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${IMAGE_NAME%:*}:test ${no_color}"
    log_and_echo ""
    log_and_echo "4. Once the problem has been diagnosed and fixed, check in the changes to the Dockerfile and project into your IBM DevOps Services project and re-run this Pipeline."
    log_and_echo ""
    log_and_echo "If the image is working locally, a deployment can still fail for a number of reasons. For more information, see the troubleshooting documentation: ${label_color} https://www.ng.bluemix.net/docs/starters/container_troubleshoot.html ${no_color}."
    log_and_echo ""
}

dump_info () {
    log_and_echo "$LABEL" "Container Information: "
    log_and_echo "$LABEL" "Information about this organization and space:"
    log_and_echo "$INFO" " Summary:"
    ice_retry_save_output info 2>/dev/null
    local ICEINFO=$(cat iceretry.log)
    log_and_echo "$ICEINFO"


    # check memory limit, warn user if we're at or approaching the limit
    export MEMORY_LIMIT=$(echo "$ICEINFO" | grep "Memory limit" | awk '{print $5}')
    # if memory limit is disabled no need to check and warn
    if [ ! -z ${MEMORY_LIMIT} ]; then
        if [ ${MEMORY_LIMIT} -ge 0 ]; then
            export MEMORY_USAGE=$(echo "$ICEINFO" | grep "Memory usage" | awk '{print $5}')
            local MEM_WARNING_LEVEL="$(echo "$MEMORY_LIMIT - 512" | bc)"

            if [ ${MEMORY_USAGE} -ge ${MEMORY_LIMIT} ]; then
                log_and_echo "$ERROR" "You are using ${MEMORY_USAGE} MB of memory, and may have reached the default limit for memory used "
            elif [ ${MEMORY_USAGE} -ge ${MEM_WARNING_LEVEL} ]; then
                log_and_echo "$WARN" "You are using ${MEMORY_USAGE} MB of memory, which is approaching the limit of ${MEMORY_LIMIT}"
            fi
        fi
    fi

#    export IP_LIMIT=$(echo "$ICEINFO" | grep "Floating IPs limit" | awk '{print $5}')
#    export IP_COUNT=$(echo "$ICEINFO" | grep "Floating IPs usage" | awk '{print $5}')
#
#    local AVAILABLE="$(echo "$IP_LIMIT - $IP_COUNT" | bc)"
#    if [ ${AVAILABLE} -le 0 ]; then
#        echo -e "${red}You have reached the default limit for the number of available public IP addresses${no_color}"
#    else
#        echo -e "${label_color}You have ${AVAILABLE} public IP addresses remaining${no_color}"
#    fi

    log_and_echo "Groups: "
    log_and_echo `ice group list 2> /dev/null`
    log_and_echo "Routes: "
    log_and_echo `cf routes`
    log_and_echo "Running Containers: "
    log_and_echo `ice ps 2> /dev/null`
    log_and_echo "Floating IP addresses"
    log_and_echo `ice ip list 2> /dev/null`
    log_and_echo "Images:"
    log_and_echo `ice images`
    return 0
}

update_inventory(){
    local TYPE=$1
    local NAME=$2
    local ACTION=$3
    if [ $# -ne 3 ]; then
        log_and_echo "$ERROR" "updating inventory expects a three inputs: 1. type 2. name 3. action. Where type is either group or container, and the name is the name of the container being added to the inventory."
        return 1
    fi
    local ID="undefined"
    # find the container or group id
    if [ "$TYPE" == "ibm_containers" ]; then
        ice_retry_save_output inspect ${NAME} 2> /dev/null
        ID=$(grep "\"Id\":" iceretry.log | awk '{print $2}')
        local RESULT=$?
        if [ $RESULT -ne 0 ]; then
            log_and_echo "$ERROR" "Could not find container called $NAME"
            ice ps 2> /dev/null
            return 1
        fi

    elif [ "${TYPE}" == "ibm_containers_group" ]; then
        ice_retry_save_output group inspect ${NAME} 2> /dev/null
        ID=$(grep "\"Id\":" iceretry.log | awk '{print $2}')
        if [ $RESULT -ne 0 ]; then
            log_and_echo "$ERROR" "Could not find group called $NAME"
            ice group list 2> /dev/null
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
        ice_retry_save_output inspect ${WAITING_FOR} 2> /dev/null
        STATE=$(grep "Status" iceretry.log | awk '{print $2}' | sed 's/"//g')
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
        ice_retry_save_output inspect $ 2> /dev/null
        STATE=$(grep "Status" iceretry.log | awk '{print $2}' | sed 's/"//g')
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
    ice inspect ${MY_CONTAINER_NAME} > /dev/null
    local FOUND=$?
    if [ ${FOUND} -eq 0 ]; then
        log_and_echo "$ERROR" "${MY_CONTAINER_NAME} already exists.  Please remove these containers or change the Name of the container or group being deployed"
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
        BIND_PARMS="--bind ${BIND_TO}"
    fi
    # run the container and check the results
    log_and_echo "run the container: ice run --name ${MY_CONTAINER_NAME} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${IMAGE_NAME} "
    ice_retry run --name ${MY_CONTAINER_NAME} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} ${BIND_PARMS} ${IMAGE_NAME} 2> /dev/null
    local RESULT=$?
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
            log_and_echo "$WARN" "'ice rm ${MY_CONTAINER_NAME}' command failed with return code ${RESULT}"
            log_and_echo "$WARN" "Removing Container instance ${MY_CONTAINER_NAME} is not completed"
        fi
        print_run_fail_msg
    fi
    return ${RESULT}
}

deploy_simple () {
    local MY_CONTAINER_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    deploy_container ${MY_CONTAINER_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Error encountered with simple build strategy for ${CONTAINER_NAME}_${BUILD_NUMBER}"
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed deployment"
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
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed deployment of ${MY_CONTAINER_NAME}"
        exit $RESULT
    fi

    # Cleaning up previous deployments. "
    clean
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed to cleanup previous deployments after deployment of ${MY_CONTAINER_NAME}"
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
        log_and_echo "Requesting IP"
        ice_retry_save_output ip request 2> /dev/null
        FLOATING_IP=$(awk '{print $4}' iceretry.log | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            log_and_echo "$WARN" "Failed to request new IP address, will attempt to reuse existing IP"
            ice_retry_save_output ip list 2> /dev/null
            FLOATING_IP=$(grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}[[:space:]]*$' iceretry.log | head -n 1)
            #FLOATING_IP=$(ice ip list 2> /dev/null | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n 1)
            #strip off whitespace
            FLOATING_IP=${FLOATING_IP// /}
            if [ -z "${FLOATING_IP}" ];then
                log_and_echo "$ERROR" "Could not request a new, or reuse an existing IP address "
                dump_info
                ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed deployment of ${MY_CONTAINER_NAME}.  Unable to allocate IP address."
                exit 1
            else
                log_and_echo "Assigning existing IP address $FLOATING_IP"
            fi
        else
            # strip off junk
            temp="${FLOATING_IP%\"}"
            FLOATING_IP="${temp#\"}"
            log_and_echo "Assigning new IP address $FLOATING_IP"
        fi
        ice_retry ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            log_and_echo "$ERROR" "Failed to bind ${FLOATING_IP} to ${CONTAINER_NAME}_${BUILD_NUMBER} "
            log_and_echo "Unsetting TEST_URL"
            export TEST_URL=""
            dump_info
            ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed binding of IP address to ${MY_CONTAINER_NAME}"
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
    local containerName=""
    # add the container name that need to keep in an array
    for (( i = 0 ; i < $CONCURRENT_VERSIONS ; i++ ))
    do
        KEEP_BUILD_NUMBERS[$i]="${CONTAINER_NAME}_$(($BUILD_NUMBER-$i))"
    done
    # add the current containers in an array of the container name
    ice_retry_save_output ps -q 2> /dev/null
    local CONTAINER_NAME_ARRAY=$(grep ${CONTAINER_NAME} iceretry.log | awk '{print $2}')
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$WARN" "'ice ps -q' command failed with return code ${RESULT}"
        log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
        return 0
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
                        log_and_echo "$WARN" "'ice ip unbind ${FLOATING_IP} ${containerName}' command failed with return code ${RESULT}"
                        log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
                        return 0
                    fi
                    sleep 2
                    ice_retry ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
                    RESULT=$?
                    if [ $RESULT -ne 0 ]; then
                        log_and_echo "$WARN" "'ice ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER}' command failed with return code ${RESULT}"
                        log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
                        return 0
                    fi
                fi
            fi
        fi
        if [ $CONTAINER_VERSION_NUMBER -gt $BUILD_NUMBER ]; then
            log_and_echo "$WARN" "The container ${containerName} version is greater then the current build number ${BUILD_NUMBER} and it will not be removed."
            log_and_echo "$WARN" "You may remove it with the ice cli command 'ice rm -f ${containerName}'"
        elif [[ " ${KEEP_BUILD_NUMBERS[*]} " == *" ${containerName} "* ]]; then
            # this is the concurrent version so keep it around
            log_and_echo "keeping deployment: ${containerName}"
        else
            log_and_echo "removing previous deployment: ${containerName}"
            ice_retry rm -f ${containerName} 2> /dev/null
            RESULT=$?
            if [ $RESULT -ne 0 ]; then
                log_and_echo "$WARN" "'ice rm -f ${containerName}' command failed with return code ${RESULT}"
                log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
                return 0
            fi
            delete_inventory "ibm_containers" ${containerName}
            FIND_PREVIOUS="true"
        fi
        IP_JUST_FOUND=""
    done
    if [ FIND_PREVIOUS="false" ]; then
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
