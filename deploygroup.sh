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

dump_info () {
    echo -e "${label_color}Container Information: ${no_color}"
    echo -e "${label_color}Information about this organization and space${no_color}:"
    echo "Summary:"
    local ICEINFO=$(ice info 2>/dev/null)
    echo "$ICEINFO"


    export CONTAINER_LIMIT=$(echo "$ICEINFO" | grep "Containers limit" | awk '{print $4}')
    # if container limit is disabled no need to check and warn
    if [ ${CONTAINER_COUNT} -ge 0 ]; then
        export CONTAINER_COUNT=$(echo "$ICEINFO" | grep "Containers usage" | awk '{print $4}')
        local WARNING_LEVEL="$(echo "$CONTAINER_LIMIT - 2" | bc)"

        if [ ${CONTAINER_COUNT} -ge ${CONTAINER_LIMIT} ]; then
            echo -e "${red}You have ${CONTAINER_COUNT} containers running, and may reached the default limit on the number of containers ${no_color}"
        elif [ ${CONTAINER_COUNT} -ge ${WARNING_LEVEL} ]; then
            echo -e "${label_color}There are ${CONTAINER_COUNT} containers running, which is approaching the limit of ${CONTAINER_LIMIT}${no_color}"
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

    echo "Groups: "
    ice group list 2> /dev/null
    echo "Routes: "
    cf routes
    echo "Running Containers: "
    ice ps 2> /dev/null
    echo "Floating IP addresses"
    ice ip list 2> /dev/null
    echo "Images:"
    ice images

    return 0
}

update_inventory(){
    local TYPE=$1
    local NAME=$2
    local ACTION=$3
    if [ $# -ne 3 ]; then
        echo -e "${red}updating inventory expects a three inputs: 1. type 2. name 3. action. Where type is either group or container, and the name is the name of the container being added to the inventory.${no_color}"
        return 1
    fi
    local ID="undefined"
    # find the container or group id
    if [ "$TYPE" == "ibm_containers" ]; then
        ID=$(ice inspect ${NAME} | grep "\"Id\":" | awk '{print $2}')
        RESULT=$?
        if [ $RESULT -ne 0 ] || [ -z "${ID}" ]; then
            echo -e "${red}Could not find container called $NAME${no_color}"
            ice ps
            return 1
        fi

    elif [ "${TYPE}" == "ibm_containers_group" ]; then
        ID=$(ice group inspect ${NAME} | grep "\"Id\":" | awk '{print $2}')
        if [ $RESULT -ne 0 ] || [ -z "${ID}" ]; then
            echo -e "${red}Could not find group called $NAME${no_color}"
            ice group list
            return 1
        fi
    else
        echo -e "${red}Could not update inventory with unknown type: ${TYPE}${no_color}"
        return 1
    fi

    local JOB_TYPE=""
    # trim off junk
    local temp="${ID%\",}"
    ID="${temp#\"}"
    echo "The ID of the $TYPE is: $ID"

    # find other inventory information
    echo -e "${label_color}Updating inventory with $TYPE of $NAME ${no_color}"
    IDS_INV_URL="${IDS_URL%/}"
    IDS_REQUEST=$TASK_ID
    IDS_DEPLOYER=${JOB_NAME##*/}
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
        echo -e "${red}Could not find CF SPACE in environment, using production space id${no_color}"
    else
        # call IBM DevOps Service Inventory CLI to update the entry for this deployment
        echo "bash ids-inv -a ${ACTION} -d $IDS_DEPLOYER -q $IDS_REQUEST -r $IDS_RESOURCE -s $ID -t ${TYPE} -u $IDS_INV_URL -v $IDS_VERSION"
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
wait_for_group (){
    local WAITING_FOR=$1
    if [ -z ${WAITING_FOR} ]; then
        echo "${red}Expected container name to be passed into wait_for${no_color}"
        return 1
    fi
    COUNTER=0
    STATE="unknown"
    while [[ ( $COUNTER -lt 180 ) && ("${STATE}" != "\"CREATE_COMPLETE\"") ]]; do
        let COUNTER=COUNTER+1
        STATE=$(ice group inspect $WAITING_FOR | grep "Status" | awk '{print $2}' | sed 's/,//g')
        if [ -z "${STATE}" ]; then
            STATE="being placed"
        fi
        if [ "${STATE}x" == "\"CREATE_FAILED\"x" ]; then
            echo -e "${red}Failed to start group ${no_color}"
            return 1
        fi
        echo "${WAITING_FOR} is ${STATE}"
        sleep 3
    done
    if [ "$STATE" != "\"CREATE_COMPLETE\"" ]; then
        echo -e "${red}Failed to start group ${no_color}"
        return 1
    fi
    return 0
}

deploy_group() {
    local MY_GROUP_NAME=$1
    echo "deploying group ${MY_GROUP_NAME}"

    if [ -z MY_GROUP_NAME ];then
        echo "${red}No container name was provided${no_color}"
        return 1
    fi

    # check to see if that group name is already in use
    ice group inspect ${MY_GROUP_NAME} > /dev/null
    local FOUND=$?
    if [ ${FOUND} -eq 0 ]; then
        echo -e "${red}${MY_GROUP_NAME} already exists.${no_color}"
        exit 1
    fi

    local BIND_PARMS=""
    # validate the bind_to parameter if one was passed
    if [ ! -z "${BIND_TO}" ]; then
        echo "Binding to ${BIND_TO}"
        local APP=$(cf env ${BIND_TO})
        local APP_FOUND=$?
        if [ $APP_FOUND -ne 0 ]; then
            echo -e "${red}${BIND_TO} application not found in space.  Please confirm that you wish to bind the container to the application, and that the application exists${no_color}"
        fi
        local VCAP_SERVICES=$(echo "${APP}" | grep "VCAP_SERVICES")
        local SERVICES_BOUND=$?
        if [ $SERVICES_BOUND -ne 0 ]; then
            echo -e "${label_color}No services appear bound to ${BIND_TO}.  Please confirm that you have bound the intended services to the application.${no_color}"
        fi
        BIND_PARMS="--bind ${BIND_TO}"
    fi
    # create the group and check the results
    echo "creating group: ice group create --name ${MY_GROUP_NAME} ${BIND_PARMS} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} --desired ${DESIRED_INSTANCES} ${AUTO} ${IMAGE_NAME}"
    ice group create --name ${MY_GROUP_NAME} ${BIND_PARMS} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} --desired ${DESIRED_INSTANCES} ${AUTO} ${IMAGE_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        echo -e "${red}Failed to deploy ${MY_GROUP_NAME} using ${IMAGE_NAME}${no_color}"
        return 1
    fi

    # wait for group to start
    wait_for_group ${MY_GROUP_NAME}
    RESULT=$?
    if [ $RESULT -eq 0 ]; then
        insert_inventory "ibm_containers_group" ${MY_GROUP_NAME}
        if [[ ( -n "${ROUTE_DOMAIN}" ) && ( -n "${ROUTE_HOSTNAME}" ) ]]; then
            ice route map --hostname $ROUTE_HOSTNAME --domain $ROUTE_DOMAIN $MY_GROUP_NAME
            RESULT=$?
            if [ $RESULT -ne 0 ]; then
                echo -e "${red}Failed to map $ROUTE_HOSTNAME $ROUTE_DOMAIN to $MY_GROUP_NAME.  Please ensure that the routes are setup correctly.  You can see this with cf routes when targetting the space for this stage.${no_color}"
                cf routes
            fi
        else
            echo "${label_color}No route defined to be mapped to the container group.  If you wish to provide a Route please define ROUTE_HOSTNAME and ROUTE_DOMAIN on the Stage environment${no_color}"
        fi
    else
        echo -e "${red}Failed to deploy group${no_color}"
    fi
    return ${RESULT}
}

deploy_simple () {
    local MY_GROUP_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    deploy_group ${MY_GROUP_NAME}
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        echo -e "${red}Error encountered with simple build strategy for ${CONTAINER_NAME}_${BUILD_NUMBER}${no_color}"
        exit $RESULT
    fi
}

deploy_red_black () {
    echo -e "${label_color}Example red_black container deploy ${no_color}"
    # deploy new version of the application
    local MY_GROUP_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    deploy_group ${MY_GROUP_NAME}
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        exit $RESULT
    fi

    if [ -z "$REMOVE_FROM" ]; then
        clean
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            exit $RESULT
        fi
    else
        echo "Not removing previous instances until after testing"
    fi
    return 0
}

clean() {
    echo "Cleaning up previous deployments.  Will keep ${CONCURRENT_VERSIONS} versions active."

    if [ -z "$REMOVE_FROM" ]; then
        COUNTER=${BUILD_NUMBER}
    else
        COUNTER=$REMOVE_FROM
    fi
    local FOUND=0
    until [  $COUNTER -lt 1 ]; do
        echo "Looking for and inspecting ${CONTAINER_NAME}_${COUNTER}"
        ice group inspect ${CONTAINER_NAME}_${COUNTER} > inspect.log
        local RESULT=$?
        if [ $RESULT -eq 0 ]; then
            echo "Found previous container ${CONTAINER_NAME}_${COUNTER}"
            let FOUND+=1
            if [ $FOUND -le $CONCURRENT_VERSIONS ]; then
                # this is the previous version so keep it around
                echo "keeping deployment: ${CONTAINER_NAME}_${COUNTER}"
            elif [[ ( -n "${ROUTE_DOMAIN}" ) && ( -n "${ROUTE_HOSTNAME}" ) ]]; then
                # remove this group
                echo "removing route $ROUTE_HOSTNAME $ROUTE_DOMAIN from ${CONTAINER_NAME}_${COUNTER}"
                ice route unmap --hostname $ROUTE_HOSTNAME --domain $ROUTE_DOMAIN ${CONTAINER_NAME}_${COUNTER}
                sleep 2
                echo "removing group ${CONTAINER_NAME}_${COUNTER}"
                ice group rm ${CONTAINER_NAME}_${COUNTER}
                delete_inventory "ibm_containers_group" ${CONTAINER_NAME}_${COUNTER}
            else
                echo "removing group ${CONTAINER_NAME}_${COUNTER}"
                ice group rm ${CONTAINER_NAME}_${COUNTER}
                delete_inventory "ibm_containers_group" ${CONTAINER_NAME}_${COUNTER}
            fi
        fi
        let COUNTER-=1
    done
    echo "Cleaned up previous deployments"
    return 0
}

##################
# Initialization #
##################
# Check to see what deployment type:
#   simple: simply deploy a container and set the inventory
#   red_black: deploy new container, assign floating IP address, keep original container
echo "Deploying using ${DEPLOY_TYPE} strategy, for ${CONTAINER_NAME}, deploy number ${BUILD_NUMBER}"

check_num='^[0-9]+$'
if [ -z "$DESIRED_INSTANCES" ]; then
    export DESIRED_INSTANCES=1
elif ! [[ "$DESIRED_INSTANCES" =~ $check_num ]] ; then
    echo -e "${label_color}DESIRED_INSTANCES value is not a number, defaulting to 1 and continue deploy process.${no_color}"
    export DESIRED_INSTANCES=1
fi

# set the port numbers with --publish
if [ -z "$PORT" ]; then
    export PUBLISH_PORT="--publish 80"
else
    export PUBLISH_PORT=$(get_port_numbers "${PORT}")
fi

if [ -z "$ROUTE_HOSTNAME" ]; then
    echo -e "${label_color}ROUTE_HOSTNAME not set.  Please set the desired or existing route hostname as an environment property on the stage.${no_color}"
fi

if [ -z "$ROUTE_DOMAIN" ]; then
    echo -e "${label_color}ROUTE_DOMAIN not set, defaulting to mybluemix.net${no_color}"
    export ROUTE_DOMAIN="mybluemix.net"
fi

if [ -z "$CONCURRENT_VERSIONS" ];then
    export CONCURRENT_VERSIONS=1
fi
# Auto_recovery setting
if [ -z "$AUTO_RECOVERY" ];then
    echo -e "AUTO_RECOVERY not set, defaulting to false."
    export AUTO=""
elif [ "${AUTO_RECOVERY}" == "true" ] || [ "${AUTO_RECOVERY}" == "TRUE" ]; then
    echo -e "${label_color}AUTO_RECOVERY set to true.${no_color}"
    export AUTO="--auto"
elif [ "${AUTO_RECOVERY}" == "false" ] || [ "${AUTO_RECOVERY}" == "FALSE" ]; then
    echo -e "${label_color}AUTO_RECOVERY set to false.${no_color}"
    export AUTO=""
else
    echo -e "${label_color}AUTO_RECOVERY value is invalid. Please enter false or true value.${no_color}"
    echo -e "${label_color}Setting AUTO_RECOVERY value to false and continue deploy process.${no_color}"
    export AUTO=""
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

if [ "${DEPLOY_TYPE}" == "simple" ]; then
    deploy_simple
elif [ "${DEPLOY_TYPE}" == "simple_public" ]; then
    deploy_public
elif [ "${DEPLOY_TYPE}" == "clean" ]; then
    clean
elif [ "${DEPLOY_TYPE}" == "red_black" ]; then
    deploy_red_black
else
    echo -e "${label_color}Currently only supporting 'red_black' deployment and 'clean' strategy${no_color}"
    echo -e "${label_color}If you would like another strategy please fork https://github.com/Osthanes/deployscripts.git and submit a pull request${no_color}"
    echo -e "${label_color}Defaulting to red_black deploy${no_color}"
    deploy_red_black
fi

dump_info
exit 0
