#!/bin/bash

#########################################################
#       ./check_kube_pods.sh				#
#                                                       #
#       Nagios check script for kubernetes cluster      #
#	pods.  Uses kubectl or API to check status	#
#	for each pod.					#
#							#
#       Author:  Justin Miller                          #
#                                                       #
#########################################################

type jq >/dev/null 2>&1 || { echo >&2 "CRITICAL: The jq utility is required for this script to run."; exit 2; }

function usage {
cat <<EOF
Usage: 
  ./check_kube_pods.sh [-t <TARGETSERVER> -c <CREDENTIALSFILE>] [-k <KUBE_CONFIG>] [-n <NAMESPACE>] [-w <WARN_THRESHOLD>] [-C <CRIT_THRESHOLD]

Options:
  -t <TARGETSERVER>	# Optional, the endpoint for your Kubernetes API (otherwise will use kubectl)
  -c <CREDENTIALSFILE>	# Required if a <TARGETSERVER> API is specified, in the format outlined below
  -n <NAMESPACE>	# Namespace to check, for example, "kube-system". By default all are checked.
  -w <WARN_THRESHOLD>	# Warning threshold for number of container restarts [default: 5]
  -C <CRIT_THRESHOLD>	# Critical threshold for number of container restarts [default: 50]
  -k <KUBE_CONFIG>	# Path to kube config file if using kubectl
  -h			# Show usage / help
  -v			# Show verbose output

Credentials file format:
machine yourEndPointOrTarget login yourUserNameHere password YOURPASSWORDHERE

EOF
exit 2
}

# Comment out if you have SSL enabled on your K8 API
SSL="--insecure"
EXITCODE=0
# Default thresholds for container restarts
WARN_THRESHOLD=5
CRIT_THRESHOLD=50

while getopts ":t:c:hw:C:n:k:v" OPTIONS; do
        case "${OPTIONS}" in
                t) TARGET=${OPTARG} ;;
                c) CREDENTIALS_FILE=${OPTARG} ;;
		w) WARN_THRESHOLD=${OPTARG} ;;
		C) CRIT_THRESHOLD=${OPTARG} ;;
		n) NAMESPACE_TARGET=${OPTARG} ;;
		v) VERBOSE="true" ;;
		k) KUBE_CONFIG="--kubeconfig ${OPTARG}" ;;
                h) usage ;;
                *) usage ;;
        esac
done



if [ ! -z $TARGET ] && [ -z $CREDENTIALS_FILE ]; then 
	echo "Required argument -c <CREDENTIALSFILE> missing when specifing -t <TARGET>";
	exit 3; 
fi

WARN_THRESHOLD=$(($WARN_THRESHOLD + 0))
CRIT_THRESHOLD=$(($CRIT_THRESHOLD + 0))

if [[ -z $TARGET ]]; then
	# use kubectl when no API endpoint is specified
	type kubectl >/dev/null 2>&1 || { echo >&2 "CRITICAL: The kubectl utility is required for this script to run if no API endpoint is specified"; exit 3; }
	if [[ -z $NAMESPACE_TARGET ]]; then
		ALL_NAMESPACE_OPTION="true"
		# should return all namespaces even when we set namespaces to default
		NAMESPACES="default"
	else
		NAMESPACES="$NAMESPACE_TARGET"
	fi
else
	# API target has been specified
	# Make call to Kubernetes API to get the list of namespaces:
	if [[ -z $NAMESPACE_TARGET ]] && [[ ! -z $TARGET ]]; then 
		NAMESPACES="$(curl -sS $SSL --netrc-file $CREDENTIALS_FILE $TARGET/api/v1/namespaces)"
		NAMESPACES=$(echo "$NAMESPACES" | jq -r '.items[].metadata.name')
	else
		NAMESPACES="$NAMESPACE_TARGET"
	fi
fi


function returnResult () {
        RESULT=$(echo -e "$1: $2\n$RESULT")
        if [[ "$1" == "Critical" ]] && [ $EXITCODE -le 2 ]; then EXITCODE=2; fi
        if [[ "$1" == "Warning" ]] && [ $EXITCODE -eq 0 ]; then EXITCODE=1; fi
        if [[ "$1" == "Unknown" ]] && [ $EXITCODE -eq 0 ]; then EXITCODE=3; fi
        }

# Itterate through each namespace
for NAMESPACE in ${NAMESPACES[*]}; do
	# get deployments data for the namespace
	if [[ -z $TARGET ]]; then
		# kubectl mode
		if [[ "$ALL_NAMESPACE_OPTION" == "true" ]]; then
			PODS_STATUS=$(kubectl $KUBE_CONFIG get pods --all-namespaces -o json)
		else
			PODS_STATUS=$(kubectl $KUBE_CONFIG get pods --namespace $NAMESPACE -o json)
		fi
		
	else
		# api mode
		PODS_STATUS=$(curl -sS $SSL --netrc-file $CREDENTIALS_FILE $TARGET/api/v1/namespaces/$NAMESPACE/pods)
	fi
	if [ $(echo "$PODS_STATUS" | wc -l) -le 10 ]; then echo "CRITICAL - unable to connect to kubernetes cluster!"; exit 3; fi

	# for debugging
	#echo "$PODS_STATUS" && exit

	PODS=$(echo "$PODS_STATUS" | jq -r '.items[].metadata.name')
	# Itterate through each pod
	for POD in ${PODS[*]}; do
		POD_STATUS=$(echo "$PODS_STATUS" | jq -r '.items[] | select(.metadata.name=="'$POD'")')
		POD_CONDITION_TYPES=$(echo "$POD_STATUS" | jq -r '.status.conditions[] | .type')
		# Itterate through each condition type
		for TYPE in ${POD_CONDITION_TYPES[*]}; do
			TYPE_STATUS=$(echo "$POD_STATUS" | jq -r '.status.conditions[] | select(.type=="'$TYPE'") | .status')
			if [[ "${TYPE_STATUS}" != "True" ]]; then
				returnResult Warning "Pod: $POD  $TYPE: $TYPE_STATUS"
			else
				if [[ "$VERBOSE" == "true" ]]; then returnResult OK "Pod: $POD  $TYPE: $TYPE_STATUS"; fi
			fi
		done
		CONTAINERS=$(echo "$POD_STATUS" | jq -r '.status.containerStatuses[].name')
		# Itterate through each container
		for CONTAINER in ${CONTAINERS[*]}; do

			CONTAINER_READY=$(echo "$POD_STATUS" | jq -r '.status.containerStatuses[] | select(.name=="'$CONTAINER'") | .ready')
			CONTAINER_RESTARTS=$(echo "$POD_STATUS" | jq -r '.status.containerStatuses[] | select(.name=="'$CONTAINER'") | .restartCount')
			if (( $CONTAINER_RESTARTS > $WARN_THRESHOLD && $CONTAINER_RESTARTS < $CRIT_THRESHOLD )); then 
				returnResult Warning "Pod: $POD   Container: $CONTAINER    Ready: $CONTAINER_READY   Restarts: $CONTAINER_RESTARTS"
			elif (( $CONTAINER_RESTARTS > $CRIT_THRESHOLD )); then
				returnResult Critical "Pod: $POD   Container: $CONTAINER    Ready: $CONTAINER_READY   Restarts: $CONTAINER_RESTARTS"
			elif (( $CONTAINER_RESTARTS > 0 )); then
				returnResult OK "Pod: $POD   Container: $CONTAINER    Ready: $CONTAINER_READY   Restarts: $CONTAINER_RESTARTS"
			fi
		done	
	done
done


case $EXITCODE in
	0) printf "OK - Kubernetes pods are all OK\n" ;;
	1) printf "WARNING - One or more pods show warning status!\n" ;;
	2) printf "CRITICAL - One or more pods show critical status!\n" ;;
esac

echo "$RESULT"
exit $EXITCODE
