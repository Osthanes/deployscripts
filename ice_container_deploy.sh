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
dump_info () {
    echo -e "${label_color}Container Information: ${no_color}"
    echo "Groups: "
    ice group list

    echo "Routes: "
    cf routes 

    echo "Running Containers: "
    ice ps 
    echo "Available floating IP addresses"
    ice ip list --all
    echo "All floating IP addresses"
    ice ip list --all
 
    if [[ (-z $IP_LIMIT) || (-z $CONTAINER_LIMIT) ]]; then 
        echo "Expected Container Service Limits to be set on the environment"
        return 1
    fi 
 
    echo -e "${label_color}Current limitations:${no_color}"
    echo "     # of containers: ${CONTAINER_LIMIT}"
    echo "     # of floating IP addresses: ${IP_LIMIT}"
 
    WARNING_LEVEL="$(echo "$CONTAINER_LIMIT - 2" | bc)"
    CONTAINER_COUNT=$(ice ps -q | wc -l | sed 's/^ *//') 
    if [ ${CONTAINER_COUNT} -ge ${CONTAINER_LIMIT} ]; then 
        echo -e "${red}You have ${CONTAINER_COUNT} containers running, and may reached the default limit on the number of containers ${no_color}"
    elif [ $CONTAINER_COUNT -ge $WARNING_LEVEL ]; then
        echo -e "${label_color}There are ${CONTAINER_COUNT} containers running, which is approaching the limit of ${CONTAINER_LIMIT}${no_color}"
    fi 
 
    IP_COUNT_REQUESTED=$(ice ip list --all | grep "Number" | sed 's/.*: \([0-9]*\).*/\1/')
    IP_COUNT_AVAILABLE=$(ice ip list | grep "Number" | sed 's/.*: \([0-9]*\).*/\1/')
    echo "Number of IP Addresses currently requested: $IP_COUNT_REQUESTED"
    echo "Number of requested IP Addresses that are still available: $IP_COUNT_AVAILABLE"
    AVAILABLE="$(echo "$IP_LIMIT - $IP_COUNT_REQUESTED + $IP_COUNT_AVAILABLE" | bc)"
 
    if [ ${AVAILABLE} -eq 0 ]; then 
        echo -e "${red}You have reached the default limit for the number of available public IP addresses${no_color}"
    else
        echo -e "${label_color}You have ${AVAILABLE} public IP addresses remaining${no_color}"
    fi  
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
    if [ "$TYPE" == "container" ]; then 
        ID=$(ice inspect ${NAME} | grep "\"Id\":" | awk '{print $2}')
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            echo -e "${red}Could not find container called $NAME${no_color}"
            ice ps 
            return 1 
        fi 
    elif [ "${TYPE}" == "group"]; then
        ID=$(ice group inspect ${NAME} | grep "\"Id\":" | awk '{print $2}')
        if [ $RESULT -ne 0 ]; then
            echo -e "${red}Could not find group called $NAME${no_color}"
            ice group list 
            return 1 
        fi 
    else 
        echo -e "${red}Could not update inventory with unknown type: ${TYPE}${no_color}"
        return 1
    fi 
    # trim off junk 
    local temp="${ID%\",}"
    ID="${temp#\"}"
    echo "The ID of the $TYPE is: $ID"
 
    # find other inventory information 
    echo -e "${label_color}Updating inventory with deployment $NAME of a $TYPE ${no_color}"
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
    IDS_RESOURCE=$CF_SPACE_ID
    if [ -z "$IDS_RESOURCE" ]; then 
        echo -e "${red}Could not find CF SPACE in environment, using production space id${no_color}"
        IDS_RESOURCE="741f0392-92bd-45e2-9504-fcccfe20acd7"
    else
        echo "spaceID is ${IDS_RESOURCE}"
    fi 
 
    # call IBM DevOps Service Inventory CLI to update the entry for this deployment
    echo "bash ids-inv -a insert -d $IDS_DEPLOYER -q $IDS_REQUEST -r $IDS_RESOURCE -s $ID -t ibm_containers -u $IDS_INV_URL -v $IDS_VERSION"
    bash ids-inv -a insert -d $IDS_DEPLOYER -q $IDS_REQUEST -r $IDS_RESOURCE -s $ID -t ibm_containers -u $IDS_INV_URL -v $IDS_VERSION
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
        STATE=$(ice group inspect $WAITING_FOR | grep "Status" | awk '{print $2}' | sed 's/,//g') && echo "${WAITING_FOR} is ${STATE}"
        sleep 1
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
 
    # create the group and check the results
    ice group create --name "${MY_GROUP_NAME}" --publish 80 --min ${GROUP_MIN} --max ${GROUP_MAX} --desired ${GROUP_DESIRED} ${IMAGE_NAME}
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        echo -e "${red}Failed to deploy ${MY_GROUP_NAME} using ${IMAGE_NAME}${no_color}"
        dump_info
        return 1
    fi 

    # wait for group to start 
    wait_for_group ${MY_GROUP_NAME}
    RESULT=$?
    if [ $RESULT -eq 0 ]; then 
        if [[ ( -n "${ROUTE_DOMAIN}" ) && ( -n "${ROUTE_HOSTNAME}" ) ]]; then 
            ice route map $ROUTE_HOSTNAME $ROUTE_DOMAIN $MY_GROUP_NAME
            RESULT=$?
            if [ $RESULT -eq 0 ]; then 
                insert_inventory "containergroup" ${MY_GROUP_NAME}
            else
                echo -e "${red}Failed to map $ROUTE_HOSTNAME $ROUTE_DOMAIN to $MY_GROUP_NAME ${no_color}"
                return 1
            fi 
        else 
            echo "No route defined, so not map it to ${MY_GROUP_NAME}"
        fi 
    else 
        echo -e "${red}Failed to deploy group${no_color}"
    fi 
    return ${RESULT}
}
 
deploy_simple () {
    local MY_GROUP_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    deploy_container ${MY_GROUP_NAME}
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
 
    COUNTER=${BUILD_NUMBER}
    let COUNTER-=1
    FOUND=0
    until [  $COUNTER -lt 1 ]; do
        ice group inspect ${MY_GROUP_NAME}_${COUNTER} > inspect.log 
        RESULT=$?
        if [ $RESULT -eq 0 ]; then
            echo "Found previous container ${MY_GROUP_NAME}_${COUNTER}"
            if [ $FOUND -eq 0 ]; then 
                # this is the previous version so keep it around 
                echo "keeping previous deployment: ${MY_GROUP_NAME}_${COUNTER}"
                FOUND=1
            elif [[ ( -n "${ROUTE_DOMAIN}" ) && ( -n "${ROUTE_HOSTNAME}" ) ]]; then
                #statements
                # remove this group 
                echo "removing route $ROUTE_HOSTNAME $ROUTE_DOMAIN from ${MY_GROUP_NAME}_${COUNTER}" 
                ice route unmap $ROUTE_HOSTNAME $ROUTE_DOMAIN $MY_GROUP_NAME
                echo "removing group ${MY_GROUP_NAME}_${COUNTER}"
                ice group rm ${MY_GROUP_NAME}_${COUNTER}
                delete_inventory "group" ${MY_GROUP_NAME}_${COUNTER}
            else 
                echo "No route defined, so not unmapping it from ${MY_GROUP_NAME}_${COUNTER}"
            fi 
        fi 
        let COUNTER-=1
    done
}
    
##################
# Initialization #
##################
# Check to see what deployment type: 
#   simple: simply deploy a container and set the inventory 
#   red_black: deploy new container, assign floating IP address, keep original container 
echo "Deploying using ${DEPLOY_TYPE} strategy, for ${CONTAINER_NAME}, deploy number ${BUILD_NUMBER}"
if [ -z "$GROUP_MIN" ]; then 
 export GROUP_MIN=1
fi 
if [ -z "$GROUP_MAX" ]; then 
 export GROUP_MAX=2
fi 
if [ -z "$GROUP_DESIRED" ]; then 
  export GROUP_DESIRED=1 
fi 

if [ -z "$ROUTE_HOSTNAME" ]; then 
    echo -e "${red}ROUTE_HOSTNAME not set.  Please set the desired or existing route hostname as an environment proeprties on the stage.${no_color}"
    exit 1 
fi 
if [ -z "$ROUTE_DOMAIN" ]; then 
    echo -e "${label_color}ROUTE_DOMAIN not set, defaulting to mybluemix.net${no_color}"
    export ROUTE_DOMAIN="mybluemix.net"
fi 

if [ "${DEPLOY_TYPE}" == "simple" ]; then
    deploy_simple
elif [ "${DEPLOY_TYPE}" == "simple_public" ]; then 
    deploy_public
elif [ "${DEPLOY_TYPE}" == "red_black" ]; then 
    deploy_red_black
else 
    echo -e "${label_color}Defaulting to red_black deploy${no_color}"
    usage
    deploy_red_black
fi 
ice groups list 
ice ps 
dump_info