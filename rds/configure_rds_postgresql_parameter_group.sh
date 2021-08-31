#!/bin/bash -e

export AWS_DEFAULT_OUTPUT="json"

TARGET_PARAM_GROUP=$1

apply_param () {
  aws rds modify-db-parameter-group --db-parameter-group-name $1 --parameters "ParameterName=$2,ParameterValue=$3,ApplyMethod=immediate"
}

apply_param $TARGET_PARAM_GROUP log_transaction_sample_rate 0.1
