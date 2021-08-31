#!/bin/bash -e

export AWS_DEFAULT_OUTPUT="json"

WANTED_TAG=dataguard
WANTED_VALUE=monitored

if [[ ! $@ ]]; then
   DB_INSTANCES=$(aws resourcegroupstaggingapi get-resources --resource-type-filters rds:db \
    --query ResourceTagMappingList[].ResourceARN --output=text --tag-filters Key=$WANTED_TAG,Values=$WANTED_VALUE)
else
   DB_INSTANCES=$@
fi

apply_param () {
  aws rds modify-db-parameter-group --db-parameter-group-name $1 --parameters "ParameterName=$2,ParameterValue=$3,ApplyMethod=immediate"
}


apply_immediately? () {
  read -p "Do you apply this immediately?" yn
  case $yn in
      [Yy]* ) break;;
      [Nn]* ) exit 1;;
      * ) echo "Please answer yes or no.";;
  esac
}



for db in $DB_INSTANCES; do

  instanceid=$(echo $db | sed 's/^.*://g')
    metadata=$(aws rds describe-db-instances --db-instance-identifier $instanceid)
  paramgroup=$(echo $metadata | jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName')

  export TARGET_PARAM_GROUP=$paramgroup

  if [[ "$paramgroup" == *"default"* ]] && [[ "$paramgroup" != *"dataguard"* ]]; then
    export TARGET_PARAM_GROUP=dataguard-$instanceid
    family=$(aws rds describe-db-parameter-groups --db-parameter-group-name $paramgroup \
      --query DBParameterGroups[0].DBParameterGroupFamily | jq -r)
    group_exists=$(aws rds  describe-db-parameter-groups --query 'DBParameterGroups[].DBParameterGroupName' | grep $TARGET_PARAM_GROUP)
    if [[ ! $group_exists ]];then
      echo "Creating new parameter group: $TARGET_PARAM_GROUP"
      aws rds create-db-parameter-group --db-parameter-group-name $TARGET_PARAM_GROUP --db-parameter-group-family $family --description "dataguard parameter group"
    fi
    echo "Applying new parameter group to $instanceid: $TARGET_PARAM_GROUP"
    apply_immediately?
    aws rds modify-db-instance --db-instance-identifier $instanceid --db-parameter-group-name $TARGET_PARAM_GROUP --apply-immediately > /dev/null
    echo "Waiting for $instanceid to become available again"
    aws rds wait db-instance-available --db-instance-identifier $instanceid
  elif [[ ! "$paramgroup" == *"default"* ]] && [[ "$paramgroup" != *"dataguard"* ]]; then
    echo "Copying customized parameter group to modify"
    aws rds copy-db-parameter-group --source-db-parameter-group-identifier "$paramgroup" --target-db-parameter-group-identifier $TARGET_PARAM_GROUP
    apply_immediately?
    aws rds modify-db-instance --db-instance-identifier $instanceid --db-parameter-group-name $TARGET_PARAM_GROUP --apply-immediately > /dev/null
  fi

  aws rds wait db-instance-available --db-instance-identifier $instanceid

  echo "Updating parameters"
  apply_param $TARGET_PARAM_GROUP general_log 1
  apply_param $TARGET_PARAM_GROUP slow_query_log 1
  apply_param $TARGET_PARAM_GROUP log_output FILE

  echo "Enabling export logs on $instanceid"

  aws rds wait db-instance-available --db-instance-identifier $instanceid

  ORIG_TYPES=$(echo $metadata | jq '.DBInstances[0].EnabledCloudwatchLogsExports[]' | tr '\n' ',' | sed 's/,$//g') || " "
  TYPES=$ORIG_TYPES

      error_good=$(echo $TYPES | grep error)
    general_good=$(echo $TYPES | grep general)
  slowquery_good=$(echo $TYPES | grep slowquery)

  if [[ ! $error_good ]]; then
     export TYPES=$TYPES,\"error\"
  fi

  if [[ ! $general_good ]]; then
     export TYPES=$TYPES,\"general\"
  fi

  if [[ ! $slowquery_good ]]; then
     export TYPES=$TYPES,\"slowquery\"
  fi

  export TYPES=$(echo $TYPES | sed 's/^,//g')

  if [[ ! $ORIG_TYPES == $TYPES ]]; then
    echo "Applying instance enabled log types"
    COMMAND=$(echo aws rds modify-db-instance --db-instance-identifier $instanceid --cloudwatch-logs-export-configuration \'{\"EnableLogTypes\":[ $TYPES ]}\')
    eval $COMMAND >> /dev/null
    aws rds wait db-instance-available --db-instance-identifier $instanceid
  else
    echo "Export log types properly configured"
  fi

done
