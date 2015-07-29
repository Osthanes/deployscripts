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

debugme() {
  [[ $DEBUG = 1 ]] && "$@" || :
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
        log_and_echo "$ERROR" "Expected container name to be passed into wait_for"
        return 1
    fi
    local COUNTER=0
    local STATUS="unknown"
    while [[ ( $COUNTER -lt 180 ) ]]; do
        let COUNTER=COUNTER+1
        STATUS=$(ice group inspect $WAITING_FOR | grep "Status" | awk '{print $2}' | sed 's/,//g')
        if [ -z "${STATUS}" ]; then
            # get continer status: attribute="Name", value=${WAITING_FOR}, search_attribute="Status"
            get_container_group_value_for_given_attribute "Name" ${WAITING_FOR} "Status"
            STATUS=$require_value
        fi
        log_and_echo "${WAITING_FOR} is ${STATUS}"
        if [ "${STATUS}" == "CREATE_COMPLETE" ] || [ "${STATUS}" == "\"CREATE_COMPLETE\"" ]; then
            return 0
        elif [ "${STATUS}" == "CREATE_FAILED" ] || [ "${STATUS}" == "\"CREATE_FAILED\"" ]; then
            return 2
        fi
        sleep 3
    done
    log_and_echo "$ERROR" "Failed to start group"
    return 1
}

# function to map url route the container group
# takes a MY_GROUP_NAME, ROUTE_HOSTNAME and ROUTE_DOMAIN as the parameters
map_url_route_to_container_group (){
    local GROUP_NAME=$1
    local HOSTNAME=$2
    local DOMAIN=$3
    if [ -z ${GROUP_NAME} ]; then
        log_and_echo "$ERROR" "Expected container group name to be passed into route_container_group"
        return 1
    fi
    if [ -z ${HOSTNAME} ]; then
        log_and_echo "$ERROR" "Expected hostname name to be passed into route_container_group"
        return 1
    fi
    if [ -z ${DOMAIN} ]; then
        log_and_echo "$ERROR" "Expected domain name to be passed into route_container_group"
        return 1
    fi
    # Check domain name is valid
    # This check is not very useful ... it resturns 0 all the time and just indicates if the route is already created 
    cf check-route ${HOSTNAME} ${DOMAIN} | grep "does exist"
    local ROUTE_EXISTS=$?
    if [ ${ROUTE_EXISTS} -ne 0 ]; then
        # make sure we are using CF from our extension so that we can always call target.   
        local MYSPACE=$(${EXT_DIR}/cf target | grep Space | awk '{print $2}' | sed 's/ //g')
        log_and_echo "Route does not exist, attempting to create for ${HOSTNAME} ${DOMAIN} in ${MYSPACE}"
        cf create-route ${MYSPACE} ${DOMAIN} -n ${HOSTNAME}
        RESULT=$?
        log_and_echo "$WARN" "The created route will be reused for this stage, and will persist as an organizational route even if this container group is removed"
        log_and_echo "$WARN" "If you wish to remove this route use the following command: cf delete-route ROUTE_DOMAIN -n ROUTE_HOSTNAME"
    else 
        log_and_echo "Route already created for ${HOSTNAME} ${DOMAIN}"
        local RESULT=0
    fi 

    if [ $RESULT -eq 0 ]; then
        # Map hostnameName.domainName to the container group.
        log_and_echo "map route to container group: ice route map --hostname ${HOSTNAME} --domain $DOMAIN $GROUP_NAME"
        ice_retry route map --hostname $HOSTNAME --domain $DOMAIN $GROUP_NAME
        RESULT=$?
        if [ $RESULT -eq 0 ]; then
            # loop until the route to container group success with retun code 200 or time-out.
            local COUNTER=0
            local RESPONSE="0"
            log_and_echo "Waiting to get response code 200 from curl ${HOSTNAME}.${DOMAIN} command."
            if [ "${DEBUG}x" != "1x" ]; then
                local TIME_OUT=6
            else
                local TIME_OUT=270
            fi
            while [[ ( $COUNTER -lt $TIME_OUT ) ]]; do
                let COUNTER=COUNTER+1
                RESPONSE=$(curl --write-out %{http_code} --silent --output /dev/null ${HOSTNAME}.${DOMAIN})
                if [ "$RESPONSE" -eq 200 ]; then
                    log_and_echo "${green}Request to map route ('${HOSTNAME}.${DOMAIN}') to container group '${GROUP_NAME}' completed successfully.${no_color}"
                    break
                else
                    log_and_echo "${WARN}" "Requested route ('${HOSTNAME}.${DOMAIN}') did not return successfully (Response code = ${RESPONSE}). Sleep 10 sec and try to check again."
                    sleep 10
                fi
            done
            if [ "$RESPONSE" -ne 200 ]; then
                if [ "${DEBUG}x" != "1x" ]; then
                    log_and_echo "$WARN" "Requested route ('${HOSTNAME}.${DOMAIN}') still being setup."
                else
                    log_and_echo "$WARN" "Route ${HOSTNAME}.${DOMAIN} does not exist (Response code = ${RESPONSE}.  Please ensure that the routes are setup correctly."
                fi
                cf routes
                return 1
            fi
        else
            log_and_echo "$ERROR" "Failed to route map $HOSTNAME.$DOMAIN to $MY_GROUP_NAME."
            cf routes
            return 1
        fi
    else
        log_and_echo "$ERROR" "No route mapped to Container Group"
        return 1
    fi
    return 0
}

deploy_group() {
    local MY_GROUP_NAME=$1
    log_and_echo "deploying group ${MY_GROUP_NAME}"

    if [ -z MY_GROUP_NAME ];then
        log_and_echo "$ERROR" "No container name was provided"
        return 1
    fi

    # check to see if that group name is already in use
    ice group inspect ${MY_GROUP_NAME} > /dev/null
    local FOUND=$?
    if [ ${FOUND} -eq 0 ]; then
        log_and_echo "$ERROR" "${MY_GROUP_NAME} already exists. Please delete it or run group deployment again."
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Deployment of ${MY_GROUP_NAME} failed as the group already exists. $(get_error_info)"
        exit 1
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

    # create the group and check the results
    log_and_echo "creating group: ice group create --name ${MY_GROUP_NAME} ${BIND_PARMS} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} --desired ${DESIRED_INSTANCES} --min ${MIN_INSTANCES} --max ${MAX_INSTANCES} ${AUTO} ${IMAGE_NAME}"
    ice_retry group create --name ${MY_GROUP_NAME} ${BIND_PARMS} ${PUBLISH_PORT} ${MEMORY} ${OPTIONAL_ARGS} --desired ${DESIRED_INSTANCES} --min ${MIN_INSTANCES} --max ${MAX_INSTANCES} ${AUTO} ${IMAGE_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Failed to deploy ${MY_GROUP_NAME} using ${IMAGE_NAME}"
        return 1
    fi

    # wait for group to start
    wait_for_group ${MY_GROUP_NAME}
    RESULT=$?
    if [ $RESULT -eq 0 ]; then
        insert_inventory "ibm_containers_group" ${MY_GROUP_NAME}

        # Map route the container group
        if [[ ( -n "${ROUTE_DOMAIN}" ) && ( -n "${ROUTE_HOSTNAME}" ) && ( "$ROUTE_HOSTNAME" != "None" ) ]]; then
            map_url_route_to_container_group ${MY_GROUP_NAME} ${ROUTE_HOSTNAME} ${ROUTE_DOMAIN}
            RET=$?
            if [ $RET -eq 0 ]; then
                log_and_echo "Successfully mapped '$ROUTE_HOSTNAME.$ROUTE_DOMAIN' URL to container group '$MY_GROUP_NAME'."
            else
                if [ "${DEBUG}x" != "1x" ]; then
                    log_and_echo "$WARN" "You can check the route status with 'curl ${ROUTE_HOSTNAME}.${ROUTE_DOMAIN}' command after the deploy completed."
                else
                    log_and_echo "$ERROR" "Failed to map '$ROUTE_HOSTNAME.$ROUTE_DOMAIN' to container group '$MY_GROUP_NAME'. Please ensure that the routes are setup correctly.  You can see this with cf routes when targetting the space for this stage."
                fi
            fi
            if [ ! -z ${DEPLOY_PROPERTY_FILE} ]; then
                TEST_URL="${ROUTE_HOSTNAME}.${ROUTE_DOMAIN}"
                echo "export TEST_URL="${TEST_URL}"" >> "${DEPLOY_PROPERTY_FILE}"
                echo "export TEST_IP="${ROUTE_HOSTNAME}"" >> "${DEPLOY_PROPERTY_FILE}"
                echo "export TEST_PORT="$(echo $PORT | sed 's/,/ /g' |  awk '{print $1;}')"" >> "${DEPLOY_PROPERTY_FILE}"
            fi
			
			# display failure info, REMOVE LATER
			FAILED_GROUP=$(ice group inspect $MY_GROUP_NAME | grep "Id" | cut -f2- -d':' | sed 's/,//g')
			log_and_echo "The group ${MY_GROUP_NAME} failed due to:"
			log_and_echo "$ERROR" "$FAILED_GROUP"
			
        else
            log_and_echo "$ERROR" "No route defined to be mapped to the container group.  If you wish to provide a Route please define ROUTE_HOSTNAME and ROUTE_DOMAIN on the Stage environment."
        fi
    elif [ $RESULT -eq 2 ]; then
        log_and_echo "$ERROR" "Failed to create group."
        sleep 3
		
		# display failure info
		FAILED_GROUP=$(ice group inspect $MY_GROUP_NAME | grep "Failure" | cut -f2- -d':' | sed 's/,//g')
		log_and_echo "The group ${MY_GROUP_NAME} failed due to:"
		log_and_echo "$ERROR" "$FAILED_GROUP"
		
        ice_retry group rm ${MY_GROUP_NAME}
        if [ $? -ne 0 ]; then
            log_and_echo "$WARN" "'ice group rm ${MY_GROUP_NAME}' command failed with return code ${RESULT}"
            log_and_echo "$WARN" "Removing the failed group ${MY_GROUP_NAME} is not completed"
        else 
            log_and_echo "$WARN" "The group was removed successfully."
        fi
        print_fail_msg "ibm_containers_group"
    else
        log_and_echo "$ERROR" "Failed to deploy group"
    fi
    return ${RESULT}
}

deploy_simple () {
    local MY_GROUP_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    deploy_group ${MY_GROUP_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$ERROR" "Error encountered with simple build strategy for ${MY_GROUP_NAME}"
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed deployment of ${MY_GROUP_NAME}. $(get_error_info)"
        exit $RESULT
    fi
}

deploy_red_black () {
    log_and_echo "$LABEL" "Example red_black container deploy "
    # deploy new version of the application
    local MY_GROUP_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    deploy_group ${MY_GROUP_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed deployment of ${MY_GROUP_NAME}. $(get_error_info)"
        exit $RESULT
    fi

    if [ -z "$REMOVE_FROM" ]; then
        clean
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            ${EXT_DIR}/utilities/sendMessage.sh -l bad -m "Failed to cleanup previous groups after deployment of group ${MY_GROUP_NAME}. $(get_error_info)"
            exit $RESULT
        fi
    else
        log_and_echo "Not removing previous instances until after testing"
    fi
    return 0
}

clean() {
    log_and_echo "Cleaning up previous deployments.  Will keep ${CONCURRENT_VERSIONS} versions active."
    local RESULT=0
    local FIND_PREVIOUS="false"
    local groupName=""
    # add the group name that need to keep in an array
    for (( i = 0 ; i < $CONCURRENT_VERSIONS ; i++ ))
    do
        KEEP_BUILD_NUMBERS[$i]="${CONTAINER_NAME}_$(($BUILD_NUMBER-$i))"
    done
    # add the current group in an array of the group name
    # get list of the continer name by given attribute="Name" and search_value=${CONTAINER_NAME}
    GROUP_NAME_ARRAY=$(get_list_container_group_value_for_given_attribute "Name" ${CONTAINER_NAME})
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        log_and_echo "$WARN" "'ice --verbose group list' command failed with return code ${RESULT}"
        log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
        return 0
    fi

    # loop through the array of the group name and check which one it need to keep
    for groupName in ${GROUP_NAME_ARRAY[@]}
    do
        GROUP_VERSION_NUMBER=$(echo $groupName | sed 's#.*_##g')
        if [ $GROUP_VERSION_NUMBER -gt $BUILD_NUMBER ]; then
            log_and_echo "$WARN" "The group ${groupName} version is greater then the current build number ${BUILD_NUMBER} and it will not be removed."
            log_and_echo "$WARN" "You may remove it with the ice cli command 'ice group rm ${groupName}'"
        elif [[ " ${KEEP_BUILD_NUMBERS[*]} " == *" ${groupName} "* ]]; then
            # this is the concurrent version so keep it around
            log_and_echo "keeping deployment: ${groupName}"
        elif [[ ( -n "${ROUTE_DOMAIN}" ) && ( -n "${ROUTE_HOSTNAME}" ) ]]; then
            # unmap router and remove the group
            log_and_echo "removing route $ROUTE_HOSTNAME $ROUTE_DOMAIN from ${groupName}"
            ice_retry route unmap --hostname $ROUTE_HOSTNAME --domain $ROUTE_DOMAIN ${groupName}
            RESULT=$?
            if [ $RESULT -ne 0 ]; then
                log_and_echo "$WARN" "'ice route unmap --hostname $ROUTE_HOSTNAME --domain $ROUTE_DOMAIN ${groupName}' command failed with return code ${RESULT}"
                log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
                return 0
            fi
            sleep 2
            log_and_echo "delete inventory: ${groupName}"
            delete_inventory "ibm_containers_group" ${groupName}
            log_and_echo "removing group ${groupName}"
            ice_retry group rm ${groupName}
            RESULT=$?
            if [ $RESULT -ne 0 ]; then
                log_and_echo "$WARN" "'ice group rm ${groupName}' command failed with return code ${RESULT}"
                log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
                return 0
            fi
             FIND_PREVIOUS="true"
        else
            log_and_echo "delete inventory: ${groupName}"
            delete_inventory "ibm_containers_group" ${groupName}
            log_and_echo "removing group ${groupName}"
            ice_retry group rm ${groupName}
            RESULT=$?
            if [ $RESULT -ne 0 ]; then
                log_and_echo "$WARN" "'ice group rm ${groupName}' command failed with return code ${RESULT}"
                log_and_echo "$WARN" "Cleaning up previous deployments is not completed"
                return 0
            fi
            FIND_PREVIOUS="true"
        fi

    done
    if [ FIND_PREVIOUS="false" ]; then
        log_and_echo "No previous deployments found to clean up"
    else
        log_and_echo "Cleaned up previous deployments"
    fi
    return 0
}

##################
# Initialization #
##################
# Check to see what deployment type:
#   simple: simply deploy a container and set the inventory
#   red_black: deploy new container, assign floating IP address, keep original container
log_and_echo "$LABEL" "Deploying using ${DEPLOY_TYPE} strategy, for ${CONTAINER_NAME}, deploy number ${BUILD_NUMBER}"
${EXT_DIR}/utilities/sendMessage.sh -l info -m "New ${DEPLOY_TYPE} copntainer group deployment for ${CONTAINER_NAME} requested"


check_num='^[0-9]+$'
if [ -z "$DESIRED_INSTANCES" ]; then
    export DESIRED_INSTANCES=2
elif ! [[ "$DESIRED_INSTANCES" =~ $check_num ]] ; then
    log_and_echo "$WARN" "DESIRED_INSTANCES value is not a number, defaulting to 2 and continuing deploy process."
    export DESIRED_INSTANCES=2
fi

check_num='^[0-9]+$'
if [ -z "$MIN_INSTANCES" ]; then
    export MIN_INSTANCES=1
elif ! [[ "$MIN_INSTANCES" =~ $check_num ]] ; then
    log_and_echo "$WARN" "MIN_INSTANCES value is not a number, defaulting to 1 and continuing deploy process."
    export MIN_INSTANCES=1
fi

if [ $MIN_INSTANCES -gt $DESIRED_INSTANCES ]; then
    log_and_echo "$WARN" "DESIRED_INSTANCES is greater than MIN_INSTANCES.  Adjusting MIN to be equal to DESIRED."
    export MIN_INSTANCES=$DESIRED_INSTANCES
fi

check_num='^[0-9]+$'
if [ -z "$MAX_INSTANCES" ]; then
    export MAX_INSTANCES=10
elif ! [[ "$MAX_INSTANCES" =~ $check_num ]] ; then
    log_and_echo "$WARN" "MAX_INSTANCES value is not a number, defaulting to 10 and continuing deploy process."
    export MAX_INSTANCES=10
fi

if [ $MAX_INSTANCES -lt $DESIRED_INSTANCES ]; then
    log_and_echo "$WARN" "DESIRED_INSTANCES is less than MAX_INSTANCES.  Adjusting MAX to be equal to DESIRED."
    export MAX_INSTANCES=$DESIRED_INSTANCES
fi

# set the port numbers with --publish
if [ -z "$PORT" ]; then
    export PUBLISH_PORT="--publish 80"
else
    export PUBLISH_PORT=$(get_port_numbers "${PORT}")
fi

# if the user has not defined a Route then create one
if [ -z "${ROUTE_HOSTNAME}" ]; then
    log_and_echo "ROUTE_HOSTNAME not set.  One will be generated.  ${label_color}ROUTE_HOSTNAME can be set as an environment property on the stage${no_color}"
    if [ -z "$IDS_PROJECT_NAME" ]; then 
        log_and_echo "$ERROR" "${red}Failed to generate route based on project name${no_color}"
        export ROUTE_HOSTNAME=${TASK_ID}
    else 
        log_and_echo "$DEBUGGING" "IDS PROJECT NAME ${IDS_PROJECT_NAME}."  
        GEN_NAME=$(echo $IDS_PROJECT_NAME | sed 's/ | /-/g')
        log_and_echo "$DEBUGGING" "IDS GEN_NAME NAME ${GEN_NAME}."  
        MY_STAGE_NAME=$(echo $IDS_STAGE_NAME | sed 's/ //g')
        MY_STAGE_NAME=$(echo $MY_STAGE_NAME | sed 's/\./-/g')
        export ROUTE_HOSTNAME=${GEN_NAME}-${MY_STAGE_NAME}
    fi 
    log_and_echo "$WARN" "Generated ROUTE_HOSTNAME is ${ROUTE_HOSTNAME}."  
 fi 

# generate a route if one does not exist 
if [ -z "${ROUTE_DOMAIN}" ]; then 
    log_and_echo "ROUTE_DOMAIN not set, will attempt to find existing route domain to use. ${label_color} ROUTE_DOMAIN can be set as an environment property on the stage${no_color}"
    export ROUTE_DOMAIN=$(cf routes | tail -1 | grep -E '[a-z0-9]\.' | awk '{print $2}')
    if [ -z "${ROUTE_DOMAIN}" ]; then 
        cf domains > domains.log 
        FOUND=''
        while read domain; do
            log_and_echo "${DEBUGGING}" "looking at $domain"
            # cf spaces gives a couple lines of headers.  skip those until we find the line
            # 'name', then read the rest of the lines as space names
            if [ "${FOUND}x" == "x" ]; then
                if [[ $domain == name* ]]; then
                    FOUND="y"
                fi
                continue
            else 
                # we are now actually processing domains rather than junk 
                export ROUTE_DOMAIN=$(echo $domain | awk '{print $1}') 
                break
            fi 
        done <domains.log
            
        log_and_echo "No existing domains found, using organization domain (${ROUTE_DOMAIN})"  
    else
        log_and_echo "Found existing domain (${ROUTE_DOMAIN}) used by organization"  
    fi 
fi 

if [ -z "$CONCURRENT_VERSIONS" ];then
    export CONCURRENT_VERSIONS=1
fi
# Auto_recovery setting
if [ -z "$AUTO_RECOVERY" ];then
    log_and_echo "AUTO_RECOVERY not set, defaulting to false."
    export AUTO=""
elif [ "${AUTO_RECOVERY}" == "true" ] || [ "${AUTO_RECOVERY}" == "TRUE" ]; then
    log_and_echo "$LABEL" "AUTO_RECOVERY set to true."
    export AUTO="--auto"
elif [ "${AUTO_RECOVERY}" == "false" ] || [ "${AUTO_RECOVERY}" == "FALSE" ]; then
    log_and_echo "$LABEL" "AUTO_RECOVERY set to false."
    export AUTO=""
else
    log_and_echo "$WARN" "AUTO_RECOVERY value is invalid. Please enter false or true value."
    log_and_echo "$LABEL" "Setting AUTO_RECOVERY value to false and continue deploy process."
    export AUTO=""
fi

if [ ! -z ${DEPLOY_PROPERTY_FILE} ]; then
    echo "export GROUP_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"" >> "${DEPLOY_PROPERTY_FILE}"
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

if [ "${DEPLOY_TYPE}" == "simple" ]; then
    deploy_simple
elif [ "${DEPLOY_TYPE}" == "simple_public" ]; then
    deploy_public
elif [ "${DEPLOY_TYPE}" == "clean" ]; then
    clean
elif [ "${DEPLOY_TYPE}" == "red_black" ]; then
    deploy_red_black
else
    log_and_echo "$WARN" "Currently only supporting 'red_black' deployment and 'clean' strategy"
    log_and_echo "$WARN" "If you would like another strategy please fork https://github.com/Osthanes/deployscripts.git and submit a pull request"
    log_and_echo "$WARN" "Defaulting to red_black deploy"
    deploy_red_black
fi

dump_info
${EXT_DIR}/utilities/sendMessage.sh -l good -m "Successful ${DEPLOY_TYPE} container group deployment of ${CONTAINER_NAME}"
exit 0
