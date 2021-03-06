#!/bin/bash

setup() {
	mkdir -p /kontinuous/{src,status}/${KONTINUOUS_PIPELINE_ID}/${KONTINUOUS_BUILD_ID}/${KONTINUOUS_STAGE_ID}
}

prepare_kube_config() {
	# replace token for kube config
	sed -i "s/{{token}}/$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)/g" /root/.kube/config
}

wait_for_ready() {
	echo "Waiting for ready signal..."
	until [[ -f /kontinuous/status/${KONTINUOUS_PIPELINE_ID}/${KONTINUOUS_BUILD_ID}/${KONTINUOUS_STAGE_ID}/ready ]]; do
		sleep 5
	done
}

create_dependencies() {
	for dependency in ${DEPENDENCIES}; do
		deploy ${dependency}
	done
}

cleanup_dependencies() {
	for dependency in ${DEPENDENCIES}; do
		clean ${dependency}
	done
}

deploy(){
	echo "Deploying App to Kubernetes Cluster"
    #local deployFile="${WORKING_DIR}/${DEPLOY_FILE}"
    local deployFile="${WORKING_DIR}/$1"

    if [[ ! -f ${deployFile} ]]; then

        echo "Deploy Failed. $deployFile is unavailable."
        return 1
    fi

    kubectl apply -f ${deployFile}
    if [[ "$?" != "0" ]]; then
        echo "Deploy Failed. Unable to deploy app."
        return 1
    fi 
    echo "Deploy Successful"
    return 0
}

clean(){
    echo "Cleaning up"
    local deployFile="${WORKING_DIR}/$1"
    if [[ ! -f ${deployFile} ]]; then
        echo "Clean up Failed. File is unavailable."
        return 1
    fi

    kubectl delete -f ${deployFile}
    if [[ "$?" == "1" ]]; then
        echo "Clean up Failed. Unable to remove app from the cluster."
        exit 1
    fi 
    echo "Clean up Successful"
    return 0
}

run_image() {
	local pod_name="$1"
	# get which node the current job is running on
	local node_name=$(kubectl get pods ${pod_name} -o template --template="{{ .spec.nodeName }}" --namespace=${KONTINUOUS_NAMESPACE})

	# prepare vars
	local commands="`for cmd in ${COMMAND}; do echo \"        - ${cmd}\"; done`"
	local env_vars="`for key in ${ENV_KEYS}; do echo \"        - name: $key\"; echo \"          value: \\\"$(eval echo \\$$key)\\\"\"; done`"

	# do the sed thingy
	cp /root/pod_template.yml /tmp/pod.yml
	sed -i "s|__POD_NAME__|${pod_name}|g" /tmp/pod.yml
	sed -i "s|__NAMESPACE__|${KONTINUOUS_NAMESPACE}|g" /tmp/pod.yml
	sed -i "s|__WORKING_DIR__|${WORKING_DIR}|g" /tmp/pod.yml
	sed -i "s|__NODE_NAME__|${node_name}|g" /tmp/pod.yml
	sed -i "s|__IMAGE__|${IMAGE}|g" /tmp/pod.yml
	echo "      command:" >> /tmp/pod.yml
	echo "$commands" >> /tmp/pod.yml
	echo "      env:" >> /tmp/pod.yml
	echo "$env_vars" >> /tmp/pod.yml

	kubectl apply -f /tmp/pod.yml
}

generate_result(){
	local result="$1"
	if [[ "$result" != "0" ]]; then
			touch /kontinuous/status/${KONTINUOUS_PIPELINE_ID}/${KONTINUOUS_BUILD_ID}/${KONTINUOUS_STAGE_ID}/fail
			echo "Build Fail"
			exit 1
		else
			touch /kontinuous/status/${KONTINUOUS_PIPELINE_ID}/${KONTINUOUS_BUILD_ID}/${KONTINUOUS_STAGE_ID}/success
			echo "Build Successful"	
			exit 0
	fi
}

wait_for_success() {
	local pod_name="$1"
	# poll the pod and pass or fail

	local exit_code_line=""
	until [[ "${exit_code_line}" != "" ]]; do
		sleep 5
		exit_code_line=$(kubectl get pods ${pod_name}-cmd -o yaml --namespace="${KONTINUOUS_NAMESPACE}" | grep exitCode)
	done

	local exit_code=$(echo ${exit_code_line} | awk '{print $2}')

	if [[ "${exit_code}" == "0" ]]; then
		return 0
	fi
	return 1
}

run_command() {

	# if deployment, deploy() else do the stuff below
	shopt -s nocasematch
	if [[ "$DEPLOY" == "true" ]]; then
		deploy "${DEPLOY_FILE}"
		generate_result "$?"
	fi 
	shopt -u nocasematch

	# check if dependencies are defined
	if [[ "${DEPENDENCIES}" != "" ]]; then
		create_dependencies
	fi

	# run image as a pod in the same node as this job
	local pod_name=$(kubectl get pods --namespace=${KONTINUOUS_NAMESPACE} --selector="pipeline=${KONTINUOUS_PIPELINE_ID},build=${KONTINUOUS_BUILD_ID},stage=${KONTINUOUS_STAGE_ID}" --no-headers | awk '{print $1}')
	run_image ${pod_name}

	wait_for_success "${pod_name}"
	local result="$?"

	echo "Command Agent Logs:"
	echo "-------------------"
	# print logs afterwards
	kubectl logs --namespace="${KONTINUOUS_NAMESPACE}" "${pod_name}-cmd"

	# cleanup
	kubectl delete -f /tmp/pod.yml || true

	# check if dependencies are defined
	if [[ "${DEPENDENCIES}" != "" ]]; then
		cleanup_dependencies
	fi
	
	generate_result ${result}
}

main() {
	setup
	prepare_kube_config
	wait_for_ready
	run_command
}

main $@