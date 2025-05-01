#!/usr/bin/env bash

# TODO
# - replace read with prompt_user_for_value
# - unify response handling (extract it into a new function)
# - update script with option "post-restore check" which checks whether:
#       * all data streams are using index templates from the target cluster
#       * restored indices have the same number of documents as indices in the snapshot
#       * backing indices have ILM policies and pipelines same as data stream
#       * there are any orphaned backing indices
#       * any index has ILM errors

#
# Logging functions
#
# Log Level hierarchy:
# 1. Trace
# 2. Debug
# 3. Info
# 4. Warning
# 5. Error
# 6. Fatal

log_trace() {
    if [[ "$VERBOSE" == true ]]; then
        # two spaces before the message are required as the emoji takes up two characters
        printf "%b\n" "🔍 $1" >&2;
    fi
}

log_debug() {
    if [[ "$VERBOSE" == true ]]; then
        # two spaces before the message are required as the emoji takes up two characters
        printf "%b\n" "🐛 $1" >&2;
    fi
}

log_info() {
    if [[ "$VERBOSE" == true ]]; then
        # two spaces before the message are required as the emoji takes up two characters
        printf "%b\n" "ℹ️  $1" >&2;
    fi
}

log_error() {
    printf "%b\n" "❌ $1" >&2;
}

log_error_and_exit() {
    printf "%b\n" "❌ $1" >&2; exit 1;
}

log_warning() {
    # two spaces before the message are required as the emoji takes up two characters
    printf "%b\n" "⚠️  $1" >&2;
}

log_fatal() {
    # two spaces before the message are required as the emoji takes up two characters
    printf "%b\n" "💀 $1" >&2;
}

#
# Custom log functions
#

log_success() {
    printf "%b\n" "✅ $1" >&2;
}

log_wait() {
    printf "%b\n" "⏳ $1" >&2;
}

log_start() {
    printf "%b\n" "🚀 $1" >&2;
}

log_skip() {
    printf "%b\n" "⏩ $1" >&2;
}

log_finish() {
    printf "%b\n" "🏁 $1" >&2;
}

log_prompt() {
    printf "%b\n" "❓ $1" >&2;
}

log_empty_line() {
    printf "\n" >&2;
}

# read -p sends prompt to stderr, so we need to redirect printf to stderr as well.
# This follows the good practice of all user-facing messages being sent to stderr.
# This is important for scripts that may be used in pipelines or redirected to files.
# This way, the output of the script can be easily separated from user prompts.
#
# Output:
#   - "y" or "Y" for yes
#   - "n" or "N" for no
prompt_user_for_confirmation() {
    local message="$1"
    local default_answer="$2"
    local confirmed=false

    while true;
    do
        # printf "%b (y/n) [default: %s]: " "$message" "$default_answer" >&2
        # read -e -r answer

        read -e -r -p "$message (y/n) [default: $default_answer]: " answer
        case $answer in
            [Yy] )
                confirmed=true
                break;;
            [Nn] )
                confirmed=false
                break;;
            "" )
                if [[ "$default_answer" == "y" || "$default_answer" == "Y" ]]; then
                    confirmed=true
                else
                    confirmed=false
                fi
                break;;
            * )
                log_error "Invalid input. Please answer yes [y|Y] or no [n|N].";;
        esac
    done

    echo $confirmed
}

prompt_user_for_value() {
    local value_name="$1"
    local default_value="$2"
    local value
    local message

    if [[ -z "$value_name" ]]; then
        log_error "Value name is required."
        return 1
    fi

    if [[ -z "$default_value" ]]; then
        log_warning "Default value is not provided. Entering empty value is not allowed."
        message="❓ Please enter $value_name: "
    else
        log_info "Default value is provided. Entering empty value will be replaced with default value: $2"
        message="❓ Please enter $value_name [default: $default_value]: "
    fi

    while true; do
        printf "%b" "$message" >&2
        read -e -r value
        if [[ -z "$value" ]]; then
            if [[ -n "$default_value" ]]; then
                value="$default_value"
                log_info "Using default value: $value"
                break
            else
                log_error "Empty value is not allowed."
                continue
            fi
        else
            break
        fi
    done

    echo "$value"
}

# Log array elements with their index
# Usage:
#   log_array_elements "true" "one" "two" "three"
#
#   print_index=true
#   array_numbers=("one" "two" "three")
#   log_array_elements "$print_index" "${array_numbers[@]}"
log_array_elements() {
     # First argument is the boolean
    local print_index="$1"

    # Remove the first argument
    shift

    # Remaining arguments are the array elements
    local array=("$@")

    if [[ "$print_index" == true ]]; then
        local index=0
        for element in "${array[@]}"; do
            printf "[%d] %b\n" "$index" "$element" >&2;
            ((index++))
        done
    else
        for element in "${array[@]}"; do
            printf "%b\n" "$element" >&2;
        done
    fi
}

log_json_pretty_print() {
    local json="$1"
    printf "%b\n" "$json" | jq . >&2;
}

log_string() {
    local string="$1"
    printf "%b\n" "$string" >&2;
}

sort_array() {
  local input=("$@")
  IFS=$'\n' sorted=($(sort <<<"${input[*]}"))
  echo "${sorted[@]}"
}

#
# Global variables
#

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IGNORE_UNAVAILABLE=false
DEFAULT_INCLUDE_GLOBAL_STATE=false
DEFAULT_INCLUDE_ALIASES=true

get_cluster_state() {
    # Get the state of the cluster
    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cluster/state?pretty" \
        -H "Content-Type: application/json"
}

show_cluster_state() {
    cluster_state=$(get_cluster_state)
    # (!) Very verbose output
    echo
    echo "Cluster state:"
    echo "$cluster_state" | jq .
}

show_cluster_settings() {
    # Get the settings of the cluster
    local response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cluster/settings?pretty" \
        -H "Content-Type: application/json")
    echo "$response" | jq .
}

# Response in case of success can look like this:
# {
#   "acknowledged": true,
#   "persistent": {
#     "action": {
#       "destructive_requires_name": "false"
#     }
#   },
#   "transient": {}
# }
edit_cluster_settings() {
    echo && echo "Editing cluster settings..."

    # Ask user if it's persistent or transient settings that need to be edited
    local settings_type=""
    read -e -r -p "Enter settings type (persistent/transient): " settings_type

    if [[ -z "$settings_type" ]]; then
        echo "Settings type is required!"
        return 1
    fi

    # Ask user for the setting key
    local setting_key=""
    read -e -r -p "Enter setting key: " setting

    if [[ -z "$setting" ]]; then
        echo "Setting key is required!"
        return 1
    fi

    # Ask user for the setting value
    local setting_value=""
    read -e -r -p "Enter setting value: " setting_value

    if [[ -z "$setting_value" ]]; then
        echo "Setting value is required!"
        return 1
    fi

    # Create the request body
    local request_body="
    {
        \"$settings_type\": {
            \"$setting\": \"$setting_value\"
        }
    }"

    # Print request body
    echo "Request body: $request_body"

    echo && echo "Sending request to edit cluster settings..."

    # Edit the settings of the cluster
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X PUT \
        "$ES_HOST/_cluster/settings" \
        -H "Content-Type: application/json" \
        -d \
        "$request_body")
    echo "$response" | jq .
}

get_nodes_info() {
    # redirect the output to stderr to enforce flush as otherwise
    # this string will also be returned by the function
    echo && echo "Getting nodes info..." >&2
    # Get the IDs of the nodes in the cluster
    local response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_nodes?pretty" \
        -H "Content-Type: application/json")

    echo "$response"
}

show_master_node() {
    log_info "Fetching master node info (_nodes/_master)..."

    # Get the master node ID
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_nodes/_master?pretty" \
        -H "Content-Type: application/json")

    log_empty_line
    # log_info "_cat/nodes/master output:\n$response"
    local output
    output=$(echo "$response" | jq -r '.nodes | to_entries[] | "\(.key): \(.value.name), \(.value.ip)"')
    log_info "Currently elected master node: \n$output"
}

print_node_roles_abbreviation_chart() {
    log_info "Node roles abbreviation chart:
    c: cold node
    d: data node
    f: frozen node
    h: hot node
    i: ingest node
    l: machine learning node
    m: master-eligible node
    r: remote cluster client node
    s: content node
    t: transform node
    v: voting-only node
    w: warm node
    -: coordinating node only"
}

show_nodes_info_verbose() {
    nodes_info=$(get_nodes_info)
    echo && echo "Nodes info:" && echo
    # (!) Very verbose output
    echo "$nodes_info" | jq .
}

show_nodes_info() {
    log_info "Fetching nodes info (_cat/nodes)..."

    # Get the IDs of the nodes in the cluster
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/nodes?v&full_id=true&h=id,name,ip,node.role" \
        -H "Content-Type: application/json")

    log_empty_line
    log_info "Nodes info:\n$response"

    log_empty_line
    print_node_roles_abbreviation_chart

    log_empty_line
    show_master_node
}

# show_nodes_ids() {
#     nodes_ids=$(get_nodes_ids)
#     echo && echo "Nodes IDs:" && echo
#     echo "$nodes_ids"
# }

get_node_settings() {
    # redirect the output to stderr to enforce flush as otherwise
    # this string will also be returned by the function
    echo && echo "Getting node settings..." >&2
    # Get the settings of the nodes in the cluster
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_nodes/settings?pretty" \
        -H "Content-Type: application/json")

    echo "$response"
}

show_nodes_settings() {
    node_settings=$(get_node_settings)
    echo && echo "Nodes settings:" && echo
    # (!) Very verbose output
    # echo $node_settings | jq
    echo "$node_settings" | jq -r '.nodes | to_entries[] | "\(.key): \(.value.settings.path.logs)"'
}

# In case of success, the response will be:
# <snapshot_repository_1> <backend>
# <snapshot_repository_2> <backend>
get_snapshot_repositories() {
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/repositories?pretty" \
        -H "Content-Type: application/json")

    echo "$response"
}

verify_repositories() {
    repositories=($@)
    for index in "${!repositories[@]}"; do
        local repository="${repositories[$index]}"
        echo "Verifying repository: $repository"
        local response
        response=$(verify_repository "$repository")
        echo "$response" | jq .
        echo
    done
}

verify_repository() {
    local repository=$1
    local response
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/_snapshot/$repository/_verify?pretty")
    echo "$response"
}

get_shards_recovery_status() {
    # _recovery endpoint returns information about ongoing and completed shard recoveries for one or more indices.
    curl \
    -s \
    -u "$ES_USERNAME:$ES_PASSWORD" \
    -X GET \
    "$ES_HOST/_recovery" \
    | jq -r \
    'keys[] as $index | .[$index].shards | keys[] as $shard_arr_index | "\($index) \($shard_arr_index) \(.[$shard_arr_index].stage) \(.[$shard_arr_index].index.size.percent) \(.[$shard_arr_index].index.files.percent)"' | column -t
}

shards_status_report() {

    echo
    echo "Shards allocation across nodes:"
    echo

    # _cat/shards?h=index,shard,prirep,state,unassigned.reason
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/shards?v" \
        -H "Content-Type: application/json")
    echo "$response"

    shards_recovery_status=$(get_shards_recovery_status)
    echo
    echo "Shards recovery status (per index):"
    echo
    echo "$shards_recovery_status"

    # Shard recovery takes place during multiple process, including: creating an index for the first time, adding a replica shard, recovering from a node failure, snapshot restore, etc.
    echo && echo "Shards recovery status (per index):"
    # headers: index, shard, time, type, stage, source_host, source_node, target_host, target_node, repository,
    # snapshot, files, files_recovered, files_percent, files_total, bytes, bytes_recovered, bytes_percent,
    # bytes_total, translog_ops, translog_ops_recovered, translog_ops_percent
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/recovery?v&h=index,shard,time,type,stage,source_host,snapshot,files_percent,bytes_perent" \
        -H "Content-Type: application/json")
    echo "$response"
}

list_snapshot_repositories(){
    snapshot_repositories=$(get_snapshot_repositories)
    # echo && echo "Snapshot repositories response:" && echo "$snapshot_repositories"
    snapshot_repositories_array=($(echo "$snapshot_repositories" | awk '{print $1}'))
    # echo && echo "Snapshot repositories: " "${snapshot_repositories_array[@]}"
    echo && echo "Snapshot repositories: "
    for repo in "${snapshot_repositories_array[@]}"; do
        echo "$repo"
    done
}

verify_snapshot_repositories(){
    snapshot_repositories=$(get_snapshot_repositories)
    # echo && echo "Snapshot repositories response:" && echo "$snapshot_repositories"
    snapshot_repositories_array=($(echo "$snapshot_repositories" | awk '{print $1}'))
    echo && echo "Snapshot repositories: " "${snapshot_repositories_array[@]}"

    # If verification fails with error "Unable to load AWS credentials from any provider in the chain"
    # or "Connection pool shut down" try restarting the statefulsets:
    # kubectl rollout restart statefulset <statefulset_name> -n <elastic_namespace_name>
    verify_repositories "${snapshot_repositories_array[@]}"
}

show_slm_policies_details() {
    log_wait "Fetching Snapshot Lifecycle Management Policies for the cluster in the current environment ($ENV)..."

    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_slm/policy?pretty")

    # Extract the HTTP status code from the response
    # http_code=$(echo "$response" | tail -n1)
    http_code="${response: -3}"

    # Extract the response body
    # Remove the last 3 characters from the response to get the body
    response_body="${response:: -3}"

    # Check if the http code is 200
    if [[ "$http_code" -eq 200 ]]; then
        log_info "Response HTTP code: $http_code"

        # Check if response is JSON
        if [[ "$response_body" == *"{"* ]]; then
            # log_info "Response body:\n$(echo "$response_body" | jq .)"
            # Response is in JSON format and can be quite large therefore we're trimming it.
            # log_info "Response body (trimmed):\n$(echo "$response_body" | head -n 100)"

            # If there are no policies, the response is an empty JSON: { }
            if echo "$response_body" | jq -e 'type == "object" and length == 0' > /dev/null; then
                log_warning "The JSON is an empty object."
                log_warning "No SLM policies found."
            else
                log_info "SLM policies:"
                echo "$response_body" | jq . >&2
            fi
        else
            log_error "Response is not in JSON format."
            log_error "Response body:\n$response_body"
            return 1
        fi
    else
        log_error "Request failed. HTTP code: $http_code"

        # Check if response is JSON
        if [[ "$response_body" == *"{"* ]]; then
            log_error "Response body:\n$(echo "$response_body" | jq .)"
        else
            log_error "Response body:\n$response_body"
        fi

        return 1
    fi
}

# Usage example:
# show_templates_for_indices "index1" "index2" "index3"
#
# $ES_HOST/<index> endpoint returns information about a specific index but it does not have information about index templates.
#
# _index_template endpoint returns information about index templates. JSON response starts like this:
# {
#   "index_templates": [
#     {
#       "name": "metrics-apm.service_transaction.60m",
#       "index_template": {
#         "index_patterns": [
#           "metrics-apm.service_transaction.60m-*"
#         ],
#
# _index_template/<template_name> endpoint returns information about a specific index template. JSON response looks like this:
# {
#   "index_templates": [
#     {
#       "name": "apm-source-map",
#       "index_template": {
#         "index_patterns": [
#           ".apm-source-map"
#         ],
#         "template": {
#           "settings": {
#             "index": {
#               "hidden": "true",
#               "number_of_shards": "1",
#               "auto_expand_replicas": "0-2"
#             }
#           },
#           "mappings": {
#             "dynamic": "strict",
#             "properties": {
#               "file.path": {
#                 "type": "keyword"
#               },
#               ...
#               "content": {
#                 "type": "binary"
#               }
#             }
#           }
#         },
#         "composed_of": [], <-- this is an array of component templates
#         "version": 1
#       }
#     }
#   ]
# }
show_templates_for_indices() {
  local indices=("$@")

  all_index_templates=$(curl \
      -s \
      -u "$ES_USERNAME:$ES_PASSWORD" \
      -X GET \
      "$ES_HOST/_index_template" \
      -H "Content-Type: application/json"
  )

  for index in "${indices[@]}"; do
    echo "Index: $index"

    # templates=$(curl \
    #     -s \
    #     -u "$ES_USERNAME:$ES_PASSWORD" \
    #     -X GET \
    #     "$ES_HOST/_index_template" \
    #     -H "Content-Type: application/json" \
    #     | jq -r \
    #     '
    #         .index_templates[]
    #         | select(.index_template.index_patterns[]
    #         | test("'"$index"'"))
    #         | .name
    #     '
    # )

    templates=$(echo "$all_index_templates" | jq -r \
        --arg index "$index" \
        '.index_templates[] | select(.index_template.index_patterns[] | test($index)) | .name'
    )
    
    # Get matching index templates
    # settings.index.templates might be missing which means that No template was applied or
    # the index was manually created or pre-dates the template.
    # templates=$(curl \
    #     -s \
    #     -u "$ES_USERNAME:$ES_PASSWORD" \
    #     -X GET \
    #     "$ES_HOST/$index?filter_path=*.settings.index.templates" \
    #     -H "Content-Type: application/json"
    # )

    # if [[ $templates == "{}" ]]; then
    #   echo "  No index templates found."
    #   continue
    # fi
    
    if [ -n "$templates" ]; then
      echo "  Supporting Index Templates:"

      # Elasticsearch index can use more than one index template.
      while IFS= read -r template; do
        echo "    - $template"
        
        # Get component templates for each index template
        # components=$(curl \
        #     -s \
        #     -u "$ES_USERNAME:$ES_PASSWORD" \
        #     -X GET "$ES_HOST/_index_template/$template" \
        #     | jq -r '.index_templates[] | .index_template.composed_of[]'
        # )
        components=$(echo "$all_index_templates" | jq -r \
            --arg template "$template" \
            '.index_templates[] | select(.name == $template) | .index_template.composed_of[]'
        )

        # echo
        # echo "DEBUG: components: "
        # echo "$components"
        # echo
        
        if [ -n "$components" ]; then
          echo "      Component Templates:"
          while IFS= read -r component; do
            echo "        - $component"
          done <<< "$components"
        fi
      done <<< "$templates"
    else
      echo "  No supporting index templates found."
    fi
    echo
  done
}

show_supporting_indices_for_data_stream() {
    local data_stream_name=$1

    echo >&2
    echo "Data stream supporting (backing) indices" >&2
    echo >&2

    # If data stream name is not provided, prompt user for it

    if [[ -z "$data_stream_name" ]]; then
        read -e -r -p "Enter data stream name: " data_stream_name
        if [[ -z "$data_stream_name" ]]; then
            echo "Data stream name is required!"
            exit 1
        fi
    fi

    echo
    echo "Fetching supporting indices for data stream $data_stream_name..." >&2
    echo

    all_data_streams=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/$data_stream_name" \
        -H "Content-Type: application/json"
    )

    local indices
    indices=$(echo "$all_data_streams" | jq -r \
        '.data_streams[0].indices[].index_name'
    )

    if [ -n "$indices" ]; then
      echo "Supporting Indices:"
      while IFS= read -r index; do
        echo "$index"
      done <<< "$indices"
    else
      echo "  No supporting indices found."
    fi
    echo
}

# Data Stream can be in a Broken Rollover State
# If a rollover failed, the current write index might have been marked as completed, but no new write index was created.
# Fix: Manually retry ILM to trigger rollover.
show_data_stream_ilm_status() {
    local data_stream_name=$1

    echo >&2
    echo "Data stream ILM status" >&2
    echo >&2

    # If data stream name is not provided, prompt user for it

    if [[ -z "$data_stream_name" ]]; then
        read -e -r -p "Enter data stream name: " data_stream_name
        if [[ -z "$data_stream_name" ]]; then
            echo "Data stream name is required!"
            return 1
        fi
    fi

    echo
    echo "Fetching ILM status for data stream $data_stream_name..." >&2
    echo "(Note: it is assumed that backing indices are in form .ds-$data_stream_name)" >&2
    echo

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/.ds-$data_stream_name*/_ilm/explain" \
        -H "Content-Type: application/json"
    )

    echo "$response" | jq .

    # Go through all indices and check if they are in a broken rollover state
    # Iterate through each object in the "indices" array

    # If the "step" field is "ERROR", then print index name, phase, action and name of the failed step
    echo "$response" | jq -r '.indices | to_entries[] | if .value.step == "ERROR" then "Index \(.key) is in phase \(.value.phase) of action \(.value.action) in failed step \(.value.failed_step.name)" else empty end'
}

show_templates_for_index() {
    local index_name=$1
    echo >&2
    echo "Index templates" >&2
    echo >&2

    # If index name is not provided, prompt user for it

    if [[ -z "$index_name" ]]; then
        read -e -r -p "Enter index name: " index_name
        if [[ -z "$index_name" ]]; then
            echo "Index name is required!"
            exit 1
        fi
    fi

    echo
    echo "Fetching index and component templates for index $index_name..." >&2
    echo

    all_index_templates=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template" \
        -H "Content-Type: application/json"
    )

    templates=$(echo "$all_index_templates" | jq -r \
        --arg index "$index_name" \
        '.index_templates[] | select(.index_template.index_patterns[] | test($index)) | .name'
    )

    if [ -n "$templates" ]; then
      echo "  Supporting Index Templates:"

      # Elasticsearch index can use more than one index template.
      while IFS= read -r template; do
        echo "    - $template"

        components=$(echo "$all_index_templates" | jq -r \
            --arg template "$template" \
            '.index_templates[] | select(.name == $template) | .index_template.composed_of[]'
        )

        if [ -n "$components" ]; then
          echo "      Component Templates:"
          while IFS= read -r component; do
            echo "        - $component"
          done <<< "$components"
        fi
      done <<< "$templates"
    else
      echo "  No supporting index templates found."
    fi
    echo
}

# _data_stream endpoint returns information about data streams. JSON response looks like this:
# {
#   "data_streams": [
#     {
#       "name": ".monitoring-beats-8-mb",
#       "timestamp_field": {
#         "name": "@timestamp"
#       },
#       "indices": [
#         {
#           "index_name": ".ds-.monitoring-beats-8-mb-2025.03.02-000444",
#           "index_uuid": "fruId_SZSMasQUc4zil59g"
#         }
#       ],
#       "generation": 445,
#       "status": "GREEN",
#       "template": ".monitoring-beats-mb",
#       "ilm_policy": ".monitoring-8-ilm-policy",
#       "hidden": false,
#       "system": false,
#       "allow_custom_routing": false,
#       "replicated": false
#     },
#   ...
#
show_templates_for_data_streams() {
    local data_streams=("$@")

    # Initialize an empty associative array to track unique values
    # Bash version to 4.0 or later is required for associative arrays
    declare -A unique_tracker_index_templates

    # Initialize the new array for unique values
    unique_array_of_index_templates=()

    declare -A unique_tracker_component_templates
    unique_array_of_component_templates=()

    all_data_strams=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/*?expand_wildcards=all&pretty" \
        -H "Content-Type: application/json"
    )

    all_index_templates=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template" \
        -H "Content-Type: application/json"
    )

    for data_stream in "${data_streams[@]}"; do
        echo "Data Stream: $data_stream"

        index_templates=$(echo "$all_data_strams" | jq -r \
            --arg data_stream "$data_stream" \
            '.data_streams[] | select(.name == $data_stream) | .template'
        )

        if [ -n "$index_templates" ]; then
            echo "  Supporting Index Templates:"

            # read one line from "$index_templates" in each loop iteration
            while IFS= read -r index_template; do
                echo "    - $index_template"

                # Check if the item is not in the unique_tracker_index_templates
                if [[ -z ${unique_tracker_index_templates[$index_template]} ]]; then
                    # Add the item to the unique_array_of_index_templates
                    unique_array_of_index_templates+=("$index_template")
                    # Mark the item as seen in the unique_tracker_index_templates
                    unique_tracker_index_templates[$index_template]=1
                fi
                
                # Get component templates for each index template
                # components=$(curl \
                #     -s \
                #     -u "$ES_USERNAME:$ES_PASSWORD" \
                #     -X GET "$ES_HOST/_index_template/$template" \
                #     | jq -r '.index_templates[] | .index_template.composed_of[]'
                # )

                component_templates=$(echo "$all_index_templates" | jq -r \
                    --arg index_template "$index_template" \
                    '.index_templates[] | select(.name == $index_template) | .index_template.composed_of[]'
                )

                if [ -n "$component_templates" ]; then
                    echo "      Component Templates:"
                    while IFS= read -r component_template; do
                        echo "        - $component_template"

                        if [[ -z ${unique_tracker_component_templates[$component_template]} ]]; then
                            unique_array_of_component_templates+=("$component_template")
                            # Mark the item as seen in the unique_tracker_index_templates
                            unique_tracker_component_templates[$component_template]=1
                        fi

                    done <<< "$component_templates"
                fi
            # use a here-string (<<<) to feed the content of $index_templates directly into the while loop
            done <<< "$index_templates"
        else
            echo "  No supporting index templates found."
        fi
        echo
    done

    # Print the unique array
    # echo "List of index templates (unique values): ${unique_array_of_index_templates[*]}"
    
    # Print the unique array
    echo
    echo
    echo "Index templates which are supporting data stream(s) (unique values):"
    echo
    for index_template in "${unique_array_of_index_templates[@]}"; do
        echo "$index_template"
    done

    # Print the unique array of component templates
    echo
    echo
    echo "Component templates which are used in index streams supporting data stream(s) (unique values):"
    echo
    for component_template in "${unique_array_of_component_templates[@]}"; do
        echo "$component_template"
    done
}

show_ilm_policy_names_for_indices() {
    local indices=("$@")

    declare -A unique_ilm_policy_names
    unique_array_of_ilm_policy_names=()

    echo "List of indices and their ILM policy names:"

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/.*,*/_ilm/explain?only_managed=false&pretty" \
        -H "Content-Type: application/json"
    )

    for index in "${indices[@]}"; do
        echo "$index"

        # Get the ILM policy name for the index
        ilm_policy_name=$(echo "$response" | jq -r \
            --arg index "$index" \
            '.indices[$index].policy'
        )

        if [[ -z "$ilm_policy_name" || "$ilm_policy_name" == "null" ]]; then
            # echo "  No ILM policy found for index: $index"
            continue
        fi

        echo "  $ilm_policy_name"

        if [[ -z ${unique_ilm_policy_names[$ilm_policy_name]} ]]; then
            unique_array_of_ilm_policy_names+=("$ilm_policy_name")
            unique_ilm_policy_names[$ilm_policy_name]=1
        fi
    done

    echo
    echo "ILM policy names for indices (unique values):"
    echo
    for ilm_policy_name in "${unique_array_of_ilm_policy_names[@]}"; do
        echo "$ilm_policy_name"
    done
}

get_snapshot_info() {
    local snapshot_repository=$1
    local snapshot_name=$2
    local response

    if [[ -z "$snapshot_repository" ]]; then
        while true; do
            if ! snapshot_repository=$(prompt_user_for_value "Snapshot repository"); then
                log_error "Snapshot repository is required!"
                continue
            else
                break
            fi
        done
    fi

    if [[ -z "$snapshot_name" ]]; then
        while true; do
            if ! snapshot_name=$(prompt_user_for_value "Snapshot name"); then
                log_error "Snapshot name is required!"
                continue
            else
                break
            fi
        done
    fi

    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_snapshot/$snapshot_repository/$snapshot_name?pretty" \
        -H "Content-Type: application/json")

    # Extract the HTTP status code from the response (3 last characters)
    http_code="${response: -3}"
    # Extract the response body (all but 3 last characters)
    response_body="${response:: -3}"
    # Check if the http code is 200
    if [[ "$http_code" -eq 200 ]]; then
        log_info "Response HTTP code: $http_code"

        # Check if response is JSON
        if [[ "$response_body" == *"{"* ]]; then
            # log_info "Response body:\n$(echo "$response_body" | jq .)"
            # Response is in JSON format and can be quite large therefore we're trimming it.
            # log_info "Response body (trimmed):\n$(echo "$response_body" | head -n 100)"

            # If there are no policies, the response is an empty JSON: { }
            if echo "$response_body" | jq -e 'type == "object" and length == 0' > /dev/null; then
                log_warning "Response JSON is an empty object."
                return 1
            fi
        else
            log_error "Response is not in JSON format."
            log_error "Response body:\n$response_body"
            return 1
        fi
    else
        log_error "Request failed. HTTP code: $http_code"

        # Check if response is JSON
        if [[ "$response_body" == *"{"* ]]; then
            log_error "Response body:\n$(echo "$response_body" | jq .)"
        else
            log_error "Response body:\n$response_body"
        fi

        return 1
    fi

    echo "$response_body"
}

get_snapshot_data_streams() {
    local snapshot_info_json=$1
    local sorted_by_name=$2
    local response

    if [[ -z "$snapshot_info_json" ]]; then
        log_error "Snapshot info json is required!"
        return 1
    fi

    if $sorted_by_name; then
        response=$(echo "$snapshot_info_json" | jq -r '.snapshots[0].data_streams[]' | sort)
    else
        response=$(echo "$snapshot_info_json" | jq -r '.snapshots[0].data_streams[]')
    fi

    echo "$response"
}

get_data_streams_from_snapshot() {
    local snapshot_repository="$1"
    local snapshot_name="$2"

    if [[ -z "$snapshot_name" ]]; then
        if ! snapshot_name=$(prompt_user_for_value "Snapshot name"); then
            log_error "Snapshot name is required!"
            return 1
        fi
    fi

    local json_response
    if ! json_response=$(get_snapshot_info "$snapshot_repository" "$snapshot_name"); then
        log_error "Failed to get snapshot info for repository: $snapshot_repository and snapshot: $snapshot_name"
        return 1
    fi

    log_empty_line
    local ret_val
    if ! ret_val=$(get_snapshot_data_streams "$json_response" true); then
        log_error "Failed to get data streams for snapshot: $latest_snapshot"
        return 1
    fi

    echo "$ret_val"
}

# Retruns the snapshot repository name
prompt_user_to_select_snapshot_repository(){
    local snapshot_repositories
    snapshot_repositories=$(get_snapshot_repositories)

    # echo && echo "Snapshot repositories response:" && echo "$snapshot_repositories"
    local snapshot_repositories_array=($(echo "$snapshot_repositories" | awk '{print $1}'))
    if [ ${#snapshot_repositories_array[@]} -eq 0 ]; then
        log_warning "No snapshot repositories found!"
        return 1
    fi

    # User selects which repository to use
    local snapshot_repository=""
    log_empty_line
    log_prompt "Select a snapshot repository:"
    select snapshot_repository in "${snapshot_repositories_array[@]}"; do
        if [[ -n "$snapshot_repository" ]]; then
            # log_debug "Selected snapshot repository: $snapshot_repository"
            break
        else
            log_error "Invalid selection. Please choose a valid repository."
        fi
    done

    printf "%s" "$snapshot_repository"
}

extract_env_from_snapshot_name() {
    local snapshot_name=$1

    if [[ -z "$snapshot_name" ]]; then
        log_error "Snapshot name is required!"
        return 1
    fi

    # Assuming the snapshot name is in the format "mycorp-<env>-<repository_name>"
    # For example, if the snapshot name is "mycorp-test-repo", env will be "test"
    local env
    if ! env=$(printf "%s" "$snapshot_name" | cut -d'-' -f2); then
        log_error "Failed to extract environment from snapshot name: $snapshot_name"
        return 1
    fi

    printf "%s" "$env"
}

show_latest_snapshot_details() {
    local snapshot_repository
    if ! snapshot_repository=$(prompt_user_to_select_snapshot_repository); then
        log_error "Failed to select snapshot repository!"
        return 1
    fi
    log_info "Selected snapshot repository: $snapshot_repository"

    local env
    if ! env=$(extract_env_from_snapshot_name "$snapshot_repository"); then
        log_error "Failed to extract environment from snapshot repository name: $snapshot_repository"
        return 1
    fi
    log_info "Extracted environment: $env"

    # Check if the environment is valid
    if [[ "$env" != "test" && "$env" != "prod" ]]; then
        log_error "Invalid environment: $env. Please select repository in 'test' or 'prod'."
        return 1
    fi

    # Get policy names dynamically
    local policies=($(get_slm_policies "$env"))

    if [ ${#policies[@]} -eq 0 ]; then
        log_warning "No snapshot policies found!"
        return 1
    fi

    # User selects which policy to use
    log_empty_line
    log_prompt "Select a policy for which you want to get the latest snapshot info from:"
    select policy in "${policies[@]}"; do
        if [[ -n "$policy" ]]; then
            log_wait "Fetching latest snapshot for policy: $policy..."
            latest_snapshot=$(get_latest_snapshot_for_policy "$snapshot_repository" "$policy")

            if [[ -z "$latest_snapshot" ]]; then
                log_warning "No snapshots found for policy: $policy"
                return 1
            fi

            log_info "The latest snapshot found: $latest_snapshot"

            local json_response
            if ! json_response=$(get_snapshot_info "$snapshot_repository" "$latest_snapshot"); then
                log_error "Failed to get snapshot info for repository: $snapshot_repository and snapshot: $latest_snapshot"
                return 1
            fi

            log_info "Snapshot details:"
            log_json_pretty_print "$json_response"

            log_empty_line
            log_info "Snapshot indices (sorted by name):"
            log_empty_line
            snapshot_indices=$(echo "$json_response" | jq -r '.snapshots[0].indices[]' | sort)
            log_string "$snapshot_indices"

            log_empty_line
            log_info "Snapshot indices (sorted by name) with supporting index and component templates:"
            log_empty_line
            local indices=($(echo "$json_response" | jq -r '.snapshots[0].indices[]' | sort))
            show_templates_for_indices "${indices[@]}"

            log_empty_line
            local ret_val
            if ! ret_val=$(get_snapshot_data_streams "$json_response" true); then
                log_error "Failed to get data streams for snapshot: $latest_snapshot"
                return 1
            fi

            local snapshot_data_streams=()
            # Read the output string into an array. Use mapfile to assign the output to an array:
            mapfile -t snapshot_data_streams <<< "$ret_val"
            log_debug "snapshot_data_streams: ${snapshot_data_streams[*]}"

            if [[ ${#snapshot_data_streams[@]} -eq 0 ]]; then
                log_warning "No data streams found in snapshot: $latest_snapshot"
            else
                log_empty_line
                log_info "Snapshot data streams (sorted by name):"
                log_array_elements "false" "${snapshot_data_streams[@]}"

                log_empty_line
                log_info "Snapshot data streams (sorted by name) with supporting index and component templates:"
                log_empty_line
                # local data_streams=($(echo "$response" | jq -r '.snapshots[0].data_streams[]' | sort))
                show_templates_for_data_streams "${snapshot_data_streams[@]}"
            fi

            log_empty_line
            log_info "Snapshot aliases (for each index):"
            log_empty_line
            show_aliases_for_indices "$snapshot_indices"

            log_empty_line
            log_info "Snapshot ILM policy names for indices in this snapshot:"
            show_ilm_policy_names_for_indices "${indices[@]}"

            # Todo: Find out why request below returns 504 Gateway Time-out
            # By then, to prevent waiting for timeout, we're returning at this point.
            return 0

            echo
            echo "Snapshot status:"
            echo
            response=$(curl \
                -s \
                -u "$ES_USERNAME:$ES_PASSWORD" \
                -X GET \
                "$ES_HOST/_snapshot/$snapshot_repository/$latest_snapshot/_status?ignore_unavailable=true" \
                -H "Content-Type: application/json"
            )

            # Check if response contains "504 Gateway Time-out" or "503 Service Unavailable"
            if [[ "$response" == *"504 Gateway Time-out"* ]] || [[ $response == *"503 Service Unavailable"* ]]; then
                echo
                echo "Response: $response"
                echo "Snapshot status is not available. Please try again later."
                return 1
            fi

            # Response can be quite verbose. Enable printing it only for debugging purposes.
            # echo "$response" | jq .

            echo
            echo "Snapshot indices (sorted by name) (from _status endpoint):"
            echo
            echo "$response" | jq -r '.snapshots[0].indices | keys[]' | sort
            echo

            break
        else
            log_error "Invalid selection. Please choose a valid policy."
        fi
    done
}

# Function to get all SLM (Snapshot Lifecycle Management) policies dynamically
get_slm_policies() {
    local cluster_env=$1
    log_empty_line
    log_wait "Fetching SLM policies for cluster in $cluster_env environment..."

    # check if env is test or prod or exit with error
    if [[ "$cluster_env" != "test" && "$cluster_env" != "prod" ]]; then
        log_error_and_exit "Invalid environment: $cluster_env. Please use 'test' or 'prod'."
    fi

    local username password host

    if [[ "$cluster_env" == "test" ]]; then
        if [[ $ENV == "test" ]]; then
            username="$ES_USERNAME"
            password="$ES_PASSWORD"
            host="$ES_HOST"
        else
            username="$ORIGIN_ES_USERNAME"
            password="$ORIGIN_ES_PASSWORD"
            host="$ORIGIN_ES_HOST"
        fi
    else
        if [[ $ENV == "test" ]]; then
            username="$ORIGIN_ES_USERNAME"
            password="$ORIGIN_ES_PASSWORD"
            host="$ORIGIN_ES_HOST"
        else
            username="$ES_USERNAME"
            password="$ES_PASSWORD"
            host="$ES_HOST"
        fi
    fi

    curl \
        -s \
        -u "$username:$password" \
        -X GET \
        "$host/_slm/policy?pretty" \
        | jq -r 'keys[]'
}

# Function to list available snapshots for a specific policy
# jq -r --arg policy "$policy_name" '.snapshots[] | select(.snapshot | contains($policy)) | .snapshot' | sort -r
get_latest_snapshot_for_policy() {
    local snapshot_repository="$1"
    local policy_name="$2"

    local response
    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_snapshot/$snapshot_repository/_all")

    # Extract the HTTP status code from the response
    # http_code=$(echo "$response" | tail -n1)
    http_code="${response: -3}"

    # Extract the response body
    # Remove the last 3 characters from the response to get the body
    response_body="${response:: -3}"

    # Check if the http code is 200
    if [[ "$http_code" -eq 200 ]]; then
        log_info "Response HTTP code: $http_code"

        # Check if response is JSON
        if [[ "$response_body" == *"{"* ]]; then
            # log_info "Response body:\n$(echo "$response_body" | jq .)"
            # Response is in JSON format and can be quite large therefore we're trimming it.
            # log_info "Response body (trimmed):\n$(echo "$response_body" | head -n 100)"

            # Sometimes the response looks like this:
            # {"snapshots":[],"total":0,"remaining":0}
            local total_snapshots
            total_snapshots=$(echo "$response_body" | jq -r '.total')
            log_info "Total number of snapshots: $total_snapshots"

            if [[ "$total_snapshots" -eq 0 ]]; then
                log_error "No snapshots found for policy: $policy_name"
                return 1
            fi
        else
            log_error "Response is not in JSON format."
            log_error "Response body:\n$response_body"
            return 1
        fi
    else
        log_error "Request failed. HTTP code: $http_code"

        # Check if response is JSON
        if [[ "$response_body" == *"{"* ]]; then
            log_error "Response body:\n$(echo "$response_body" | jq .)"
        else
            log_error "Response body:\n$response_body"
        fi

        return 1
    fi

    echo "$response_body" | jq -r \
            --arg policy "$policy_name" \
            '.snapshots | map(select(.metadata.policy == $policy)) | max_by(.start_time_in_millis) | .snapshot'
}

# Function to trigger restoring a snapshot by name
# If necessary, consider adding the following parameters to the restore request:
#   \"rename_pattern\": \"(.+)\",
#   \"rename_replacement\": \"\1_restored\",
#   \"include_aliases\": false,
#
# ignore_unavailable: true - request ignores any index or data stream in indices that’s missing from the snapshot.
# The default value for ignore_unavailable is false. This means that by default, Elasticsearch will fail the
# restore operation if any specified index is missing or closed, ensuring data integrity but potentially
# interrupting the restore process.
#
# include_global_state: true - restores cluster-wide settings. These include index templates, ingest pipelines,
#   and more. Index templates are required for restoring data streams.
#
# Response in case of success:
# {
#   "accepted": true
# }
#
# or 
#
# {
#   "snapshot" : {
#     "snapshot" : "daily-snap-default-2025.02.25-_uxbsrzmsbc8lhm0pzaqkq",
#     "indices" : [ ],
#     "shards" : {
#       "total" : 0,
#       "failed" : 0,
#       "successful" : 0
#     }
#   }
# }
restore_snapshot_request() {
    local snapshot_repository="$1"
    local snapshot_name="$2"
    local request_body="$3"

    log_wait "Sending a request to restore snapshot: $snapshot_name..."

    curl \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/_snapshot/$snapshot_repository/$snapshot_name/_restore?pretty" \
        -H "Content-Type: application/json" \
        -d "$request_body"

   log_info "Restore request sent."
}

# Function to monitor restore progress
# curl -u $ES_USERNAME:$ES_PASSWORD \
# -s \
# -X GET \
# $ES_HOST \
# | jq -r \
# 'keys[] as $index | .[$index].shards | keys[] as $shard_arr_index | "\($index) \($shard_arr_index) \(.[$shard_arr_index].stage) \(.[$shard_arr_index].index.size.percent) \(.[$shard_arr_index].index.files.percent)"' | column -t
# to get the progress of the restore operation for each shard, like this:
# .internal.alerts-observability.metrics.alerts-default-000001                         0  DONE  100.0%  100.0%
# .internal.alerts-observability.metrics.alerts-default-000001                         1  DONE  0.0%    0.0%
check_restore_progress() {
    log_wait "Monitoring restore progress..."

    while true; do
        # Returned JSON is a list of indices where each index info contains the list of shards.
        # Each shard info object contains stage attribute. Its values can include:
        #   INIT - Recovery has not started.
        #   INDEX - Reading index metadata and copying bytes from source to destination.
        #   VERIFY_INDEX - Verifying the integrity of the index.
        #   TRANSLOG - Replaying transaction log.
        #   FINALIZE - Cleanup.
        #   DONE - Complete.
        progress=$(curl \
            -s \
            -u "$ES_USERNAME:$ES_PASSWORD" \
            -X GET "$ES_HOST/_recovery" \
            | jq -r '[.[] | .shards[].stage] | unique | @csv'
        )
        log_info "Current restore stages: $progress"

        if [[ "$progress" == '"DONE"' ]]; then
            log_success "Restore completed successfully!"
            break
        fi

        sleep 10
    done
}

check_cluster_health() {
    log_wait "Checking cluster health..."

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cluster/health?pretty" \
        -H "Content-Type: application/json")

    echo "$response" | jq .
}

build_list_of_indices_to_include() {
    local included_indices=""
    local DEFAULT_INCLUDED_INDICES="*"

    log_info "Default indices to include: $DEFAULT_INCLUDED_INDICES"

    # Prompt user for indices to include e.g. .alerts-observability-*,.transform-notifications-*
    printf "❓ Enter a comma-separated list of indices and/or data streams to include in the restore operation (wildcards allowed; leave empty for all): "
    read -e -r user_included_indices

    if [[ -n "$user_included_indices" ]]; then
        included_indices="$user_included_indices"
    else
        included_indices="$DEFAULT_INCLUDED_INDICES"
    fi

    echo "$included_indices"
}

build_list_of_indices_to_exclude() {
    local excluded_indices=""

    log_info "Default indices to exclude: $DEFAULT_EXCLUDED_INDICES"

    # Prompt user for indices to exclude e.g. -.transform-notifications-*,
    printf "❓ Enter a comma-separated list of additional indices to exclude from restoring snapshot (start each template/name with '-'; leave empty for none): "
    read -e -r user_excluded_indices

    # Merge DEFAULT_EXCLUDED_INDICES and user_excluded_indices
    if [[ -n "$user_excluded_indices" ]]; then
        if [[ -n "$DEFAULT_EXCLUDED_INDICES" ]]; then
            excluded_indices="$DEFAULT_EXCLUDED_INDICES,$user_excluded_indices"
        else
            excluded_indices="$user_excluded_indices"
        fi
    else
        excluded_indices="$DEFAULT_EXCLUDED_INDICES"
    fi

    echo "$excluded_indices"
}

build_list_of_features_to_include() {
    local features_to_restore=""

    log_info "Default features to restore: $DEFAULT_FEATURES_TO_RESTORE"

    # Prompt user for features to include e.g. transform,watcher
    printf "❓ Enter a comma-separated list of features to include when restoring snapshot (leave empty for none): "
    read -e -r user_features_to_restore

    if [[ -n "$user_features_to_restore" ]]; then
        features_to_restore="$user_features_to_restore"
    else
        features_to_restore="$DEFAULT_FEATURES_TO_RESTORE"
    fi

    echo "$features_to_restore"
}

get_user_input_include_global_state() {
    local include_global_state=""

    log_info "Default 'include_global_state' value: $DEFAULT_INCLUDE_GLOBAL_STATE"

    # Prompt user for features to include e.g. transform,watcher
    printf "❓ Enter 'include_global_state' value (true or false or leave empty for default value): "
    read -e -r include_global_state

    if [[ -z "$include_global_state" ]]; then
        include_global_state="$DEFAULT_INCLUDE_GLOBAL_STATE"
    fi

    echo "$include_global_state"
}

get_user_input_ignore_unavailable() {
    local ignore_unavailable=""

    log_info "Default 'ignore_unavailable' value: $DEFAULT_IGNORE_UNAVAILABLE"

    # Prompt user for features to include e.g. transform,watcher
    printf "❓ Enter 'ignore_unavailable' value (true or false or leave empty for default value): "
    read -e -r ignore_unavailable

    if [[ -z "$ignore_unavailable" ]]; then
        ignore_unavailable="$DEFAULT_IGNORE_UNAVAILABLE"
    fi

    echo "$ignore_unavailable"
}

get_user_input_include_aliases() {
    local include_aliases=""

    log_info "Default 'include_aliases' value: $DEFAULT_INCLUDE_ALIASES"

    # Prompt user for features to include e.g. transform,watcher
    printf "❓ Enter 'include_aliases' value (true or false or leave empty for default value - true): "
    read -e -r include_aliases

    if [[ -z "$include_aliases" ]]; then
        include_aliases="$DEFAULT_INCLUDE_ALIASES"
    fi

    echo "$include_aliases"
}

get_user_input_rename_pattern() {
    local rename_pattern=""

    # Prompt user for rename pattern e.g. (.+)
    printf "❓ Enter 'rename_pattern' value (leave empty for none): "
    read -e -r rename_pattern

    echo "$rename_pattern"
}

get_user_input_rename_replacement() {
    local rename_replacement=""

    # Prompt user for rename replacement e.g. \1_restored
    printf "❓ Enter 'rename_replacement' value (leave empty for none): "
    read -e -r rename_replacement

    echo "$rename_replacement"
}

get_user_input_ignore_index_settings() {
    local ignore_index_settings=""

    # Prompt user for ignore index settings
    # e.g. 
    # "index.lifecycle.name","index.default_pipeline","index.final_pipeline"
    printf "❓ Enter 'ignore_index_settings' value (e.g. \"index.routing.allocation.include.size\",\"index.lifecycle.name\"; leave empty for none): "
    read -e -r ignore_index_settings

    echo "$ignore_index_settings"
}

show_aliases_for_indices() {
    local indices="$1"

    # Get all aliases
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_aliases?pretty"
    )

    # Iterate over each index and get its aliases
    for index in $(echo "$indices" | tr "," "\n"); do
        aliases=$(echo "$response" | jq --arg index "$index" '.[$index].aliases? | select(. != null and . != {}) | keys[]')
        if [[ -z "$aliases" ]]; then
            # echo "No aliases found for index: $index"
            continue
        fi
        echo "Aliases for index $index: " && echo "$aliases" | jq .
    done

    # for index in $(echo $indices | tr "," "\n"); do
    #     echo "Aliases for index: $index"
    #     curl -s -u "$ES_USERNAME:$ES_PASSWORD" -X GET "$ES_HOST/$index/_alias?pretty" | jq .
    # done
}

# Restoring a snapshot into a current environment (cluster)
restore_snapshot(){
    log_info "ORIGIN_ES_USERNAME=$ES_USERNAME"
    # log_info "ORIGIN_ES_PASSWORD=$ES_PASSWORD"
    log_info "ORIGIN_ES_HOST=$ORIGIN_ES_HOST"
    log_info "DEFAULT_EXCLUDED_INDICES=$DEFAULT_EXCLUDED_INDICES"
    log_info "DEFAULT_FEATURES_TO_RESTORE=$DEFAULT_FEATURES_TO_RESTORE"

    local snapshot_repositories
    snapshot_repositories=$(get_snapshot_repositories)

    # Use mapfile to read the output of the command into an array
    mapfile -t snapshot_repositories_array < <(echo "$snapshot_repositories" | awk '{print $1}')

    # local snapshot_repositories_array=($(echo "$snapshot_repositories" | awk '{print $1}'))
    if [ ${#snapshot_repositories_array[@]} -eq 0 ]; then
        log_warning "No snapshot repositories found!"
        return 1
    fi

    # User selects which repository to use
    local snapshot_repository=""
    echo >&2
    log_prompt "Select a snapshot repository:"
    select snapshot_repository in "${snapshot_repositories_array[@]}"; do
        if [[ -n "$snapshot_repository" ]]; then
            log_info "Selected snapshot repository: $snapshot_repository"
            break
        else
            log_error "Invalid selection. Please choose a valid repository."
        fi
    done

    # Get policy names dynamically
    # POLICIES=($(get_slm_policies))
    # Use read to read the output of the command into an array
    mapfile -t POLICIES < <(get_slm_policies "prod")
    # echo "DEBUG: POLICIES: ${POLICIES[@]}"
    # echo "DEBUG: POLICIES: ${POLICIES[*]}"

    if [ ${#POLICIES[@]} -eq 0 ]; then
        log_warning "No snapshot policies found!"
        return 0
    fi

    # User selects which policy to use
    echo >&2
    log_prompt "Select a policy to restore a snapshot from:"
    select policy in "${POLICIES[@]}"; do
        if [[ -n "$policy" ]]; then
            log_wait "Fetching the latest snapshot for policy: $policy..."
            if latest_snapshot=$(get_latest_snapshot_for_policy "$snapshot_repository" "$policy"); then
                log_info "Latest snapshot found: $latest_snapshot"
            else
                log_error "Failed to fetch the latest snapshot for policy: $policy"
                return 1
            fi

            if [[ -z "$latest_snapshot" ]]; then
                log_warning "No snapshots found for policy: $policy"
                return 1
            fi

            echo
            log_info "The latest snapshot found: $latest_snapshot"
            log_info "Snapshot details:"
            echo

            # https://www.elastic.co/docs/api/doc/elasticsearch/v8/operation/operation-snapshot-get
            response=$(curl \
                -s \
                -u "$ES_USERNAME:$ES_PASSWORD" \
                -X GET \
                "$ES_HOST/_snapshot/$snapshot_repository/$latest_snapshot?pretty" \
                -H "Content-Type: application/json")

            echo "$response" | jq .

            # echo
            # echo "Snapshot indices (sorted by name):"
            # echo

            snapshot_indices=$(echo "$response" | jq -r '.snapshots[0].indices[]' | sort)
            # echo "$snapshot_indices"

            # Fetch all indices (including system and hidden ones) from the cluster and sort them by name
            target_cluster_indices="$(send_get_all_indices_request | awk '{print $3}' | sort)"

            # find the diff between the two arrays
            # echo "DEBUG: target_cluster_indices: $target_cluster_indices"
            # echo "DEBUG: snapshot_indices: $snapshot_indices"
            # echo "DEBUG: diff: $(diff <(echo "$target_cluster_indices") <(echo "$snapshot_indices"))"
            # echo "DEBUG: diff: $(diff <(echo "$target_cluster_indices") <(echo "$snapshot_indices") | grep -E '^[<>]')"

            # TODO: check if the diff is empty and print info message if it is
            # show only those indices which are in both arrays
            echo
            log_warning "Indices present both in the snapshot and in the cluster: "
            comm -12 <(echo "$target_cluster_indices") <(echo "$snapshot_indices")

            # echo
            # echo "Snapshot data streams (sorted by name):"
            # echo
            snapshot_data_streams=$(echo "$response" | jq -r '.snapshots[0].data_streams[]' | sort)
            cluster_data_streams="$(send_get_all_data_streams_request | jq -r '.data_streams[].name' | sort)"
            # show only those data streams which are in both arrays
            echo
            log_warning "Data streams present both in the snapshot and in the cluster: "
            comm -12 <(echo "$cluster_data_streams") <(echo "$snapshot_data_streams")

            # echo
            # echo "Snapshot aliases (for each index):"
            # echo
            # show_aliases_for_indices "$snapshot_indices"

            local indices=""
            # Prompt user to list indices to be included in the restore operation, ask to press ENTER to use the default list. default list should be only "*"
            echo
            INCLUDED_INDICES=$(build_list_of_indices_to_include)
            log_info "Indices to be included: $INCLUDED_INDICES"

            if [[ -n "$INCLUDED_INDICES" ]]; then
              indices="$INCLUDED_INDICES"
            fi

            echo
            EXCLUDED_INDICES=$(build_list_of_indices_to_exclude)
            log_info "Indices to be excluded: $EXCLUDED_INDICES"

            if [[ -n "$EXCLUDED_INDICES" ]]; then
              indices="$indices,$EXCLUDED_INDICES"
            fi

            echo
            FEATURES_TO_RESTORE=$(build_list_of_features_to_include)
            log_info "Features to be restored: $FEATURES_TO_RESTORE"

            echo
            INCLUDE_GLOBAL_STATE=$(get_user_input_include_global_state)
            log_info "Include global state: $INCLUDE_GLOBAL_STATE"

            echo
            IGNORE_UNAVAILABLE=$(get_user_input_ignore_unavailable)
            log_info "Ignore unavailable: $IGNORE_UNAVAILABLE"

            echo
            INCLUDE_ALIASES=$(get_user_input_include_aliases)
            log_info "Include aliases: $INCLUDE_ALIASES"

            local request_body="
            {
                \"indices\": \"$indices\",
                \"ignore_unavailable\": $IGNORE_UNAVAILABLE,
                \"include_global_state\": $INCLUDE_GLOBAL_STATE,
                \"feature_states\": [\"$FEATURES_TO_RESTORE\"],
                \"include_aliases\": $INCLUDE_ALIASES"

            echo
            RENAME_PATTERN=$(get_user_input_rename_pattern)
            log_info "Rename pattern: $RENAME_PATTERN"

            if [[ -n "$RENAME_PATTERN" ]]; then
                request_body="$request_body,
                \"rename_pattern\": \"$RENAME_PATTERN\""
            fi

            echo
            RENAME_REPLACEMENT=$(get_user_input_rename_replacement)
            log_info "Rename replacement: $RENAME_REPLACEMENT"

            if [[ -n "$RENAME_REPLACEMENT" ]]; then
                request_body="$request_body,
                \"rename_replacement\": \"$RENAME_REPLACEMENT\""
            fi

            echo
            IGNORE_INDEX_SETTINGS=$(get_user_input_ignore_index_settings)
            log_info "Ignore index settings: $IGNORE_INDEX_SETTINGS"

            if [[ -n "$IGNORE_INDEX_SETTINGS" ]]; then
                request_body="$request_body,
                \"ignore_index_settings\": [$IGNORE_INDEX_SETTINGS]"
            fi

            request_body="$request_body
            }"

            log_info "Request body: $request_body"

            printf "❓ Proceed with restore? (y/n): "
            read -e -r confirm
            if [[ "$confirm" == "y" ]]; then
                restore_snapshot_request "$snapshot_repository" "$latest_snapshot" "$request_body"

                log_wait "Please wait..."
                # Give some time for the restore operation to start so _recovery
                # can catch that some shards are in "INDEX" stage.
                sleep 10

                check_restore_progress

                check_cluster_health

                # ToDo: Add checking if number of documents in index from the snapshot
                # is the same in origin and target cluster
            else
                log_warning "Restore cancelled."
            fi

            break
        else
            log_error "Invalid selection. Please choose a valid policy."
        fi
    done
}

show_documents_in_index() {
    local index_name=""
    local documents_count=10

    echo >&2
    echo "Index analysis" >&2
    echo >&2

    # Prompt user for index name
    read -e -r -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        exit 1
    fi

    echo "Fetching number of documents in index: $index_name..." >&2

    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_count?pretty=true" \
         -H 'Content-Type: application/json' \
         -d \
         '{
            "query": {
                "match_all": {}
            }
        }'

    # TODO: Handle following error:
    # {
    # "error" : {
    #     "root_cause" : [
    #     {
    #         "type" : "no_shard_available_action_exception",
    #         "reason" : null
    #     }
    #     ],
    #     "type" : "search_phase_execution_exception",
    #     "reason" : "all shards failed",
    #     "phase" : "query",
    #     "grouped" : true,
    #     "failed_shards" : [
    #     {
    #         "shard" : 0,
    #         "index" : ".ds-filebeat-8.7.1-2024.11.21-000102",
    #         "node" : null,
    #         "reason" : {
    #         "type" : "no_shard_available_action_exception",
    #         "reason" : null
    #         }
    #     }
    #     ]
    # },
    # "status" : 503
    # }

    read -e -r -p "Enter how many documents to fetch from the index (default is 10): " documents_count

    if [[ -n "$documents_count" ]]; then
        echo "Fetching $documents_count documents in index: $index_name..." >&2
    else
        documents_count=10
        echo "Fetching $documents_count documents in index: $index_name..." >&2
    fi

    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_search?size=$documents_count&pretty=true" \
         -H 'Content-Type: application/json' \
         -d \
        '{
            "query": {
                "match_all": {}
            }
        }'
}

show_documents_count() {
    local index_name=$1
    echo >&2
    echo "Documents count" >&2
    echo >&2

    if [[ -z "$index_name" ]]; then
        read -e -r -p "Enter index name: " index_name
        if [[ -z "$index_name" ]]; then
            echo "Index name is required!"
            exit 1
        fi
    fi

    echo "Fetching number of documents in index / data stream: $index_name..." >&2

    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_count?pretty=true" \
         -H 'Content-Type: application/json'
}

convert_to_json() {
    local input="$1"

    # Extract key and value from input
    key=$(echo "$input" | cut -d':' -f1 | tr -d ' "')
    value=$(echo "$input" | cut -d':' -f2- | xargs) # Preserve values with spaces

    # Split the key into an array using dots
    IFS="." read -ra keys <<< "$key"

    # Build JSON from leaf to root
    temp_json="{\"${keys[-1]}\": \"$value\"}"
    for (( i=${#keys[@]}-2; i>=0; i-- )); do
        temp_json="{\"${keys[i]}\": $temp_json}"
    done

    echo "$temp_json" | jq .
}

modify_setting_for_indices() {
    echo
    echo "Modify settings for indices"
    echo

    # Prompt user for settings to modify
    local settings_=""
    read -e -r -p "Enter settings to modify (e.g. \"index.number_of_replicas\":0 or \"index.lifecycle.name\":\"my-metrics@custom\"): " settings

    if [[ -z "$settings" ]]; then
        echo "Settings are required!"
        return 1
    fi

    echo "Settings to modify: $settings"

    local settings_json
    settings_json=$(convert_to_json "$settings")

    # Prompt user for index name, ENTER for providing the file path containing the the list of indices
    local index_name=""
    local indices_file_path=""

    read -e -r -p "Enter index name (use wildcards if want to match multiple indices) or ENTER to provide file path containing the list of indices: " index_name

    local indices=()

    if [[ -z "$index_name" ]]; then
        local exit_code=0
        local output=""
        # check if read_items_from_file returns non-zero code or actual array
        # The || operator executes the right-hand command only if the left-hand command fails (i.e., returns a non-zero exit code)
        output=$(read_items_from_file) || exit_code=$?
        # echo "Exit code: $exit_code"
        

        if [[ $exit_code -ne 0 ]]; then
            echo "Error reading indices from file."
            return 1
        fi

        indices=("$output")

        # Check if array is empty
        if [[ ${#indices[@]} -eq 0 ]]; then
            echo "No index names found in file: $index_name"
            return 1
        fi
    else
        indices=("$index_name")
    fi

    # Prompt user to confirm closing of indices
    echo
    echo "The following indices will be modified:"
    echo
    
    for index in "${indices[@]}"; do
        echo "$index"
    done

    echo
    echo "The following settings will be applied:"
    echo "$settings_json"
    echo

    printf "❓ Do you want to proceed? (y/n): "
    read -e -r confirm

    if [[ "$confirm" != "y" ]]; then
        echo "Modifying of indices' settings cancelled."
        return 1
    fi

    # Modify settings for each index
    for index in "${indices[@]}"; do
        echo "Modifying settings for index: $index..."

        response=$(curl \
            -s \
            -u "$ES_USERNAME:$ES_PASSWORD" \
            -X PUT \
            "$ES_HOST/$index/_settings?pretty=true" \
            -H 'Content-Type: application/json' \
            -d \
            "$settings_json"
        )

        echo "$response" | jq .
    done
}

show_mapping_for_index() {
    local index_name=""
    echo >&2
    echo "Index mapping" >&2
    echo >&2

    # Prompt user for index name
    read -e -r -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        exit 1
    fi

    echo "Fetching mapping for index: $index_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_mapping?pretty=true" \
        -H 'Content-Type: application/json')
    echo "$response" | jq .
}

show_all_mappings_in_cluster() {
    echo >&2
    echo "All mappings in the cluster" >&2
    echo >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_mapping?pretty=true" \
        -H 'Content-Type: application/json')
    echo "$response" | jq .
}

close_index() {
    local index_name=""
    echo >&2
    echo "Close index" >&2
    echo >&2

    # Prompt user for index name
    read -e -r -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        exit 1
    fi

    echo "Closing index: $index_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/$index_name/_close?pretty=true" \
        -H 'Content-Type: application/json')
    echo "$response" | jq .
}

send_get_all_indices_request() {
    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/indices?v&expand_wildcards=all&pretty&s=index" \
        -H "Content-Type: application/json"
}

# v → Adds column headers for better readability.
# expand_wildcards=all → Ensures all indices are listed, including:
# - open indices
# - closed indices
# - hidden indices
# - system indices (if applicable)
show_indices() {

    # Prompt user whether to show used index templates
    # local used_index_templates=""
    # read -p "Show used index templates? (true/false): " used_index_templates

    # # Send request to get indices and print index names and used index templates
    # echo && echo "Fetching indices..." >&2
    # # Get the indices in the cluster
    # curl \
    #     -s \
    #     -u "$ES_USERNAME:$ES_PASSWORD" \
    #     -X GET \
    #     "$ES_HOST/_cat/indices?v&expand_wildcards=all&pretty&s=index" \
    #     -H "Content-Type: application/json"
    #     # | jq -r \
    #     # '
    #     #     . | to_entries[] |
    #     #     .key + "\n" +
    #     #     (if .value.template == "NA" then "" else "\tTemplate: " + .value.template end)
    #     # '

    echo && echo "Fetching indices..." >&2
    echo "List of indices with details:"
    echo

    # Get the indices in the cluster
    # response=$(curl \
    #     -s \
    #     -u "$ES_USERNAME:$ES_PASSWORD" \
    #     -X GET \
    #     "$ES_HOST/_cat/indices?v&expand_wildcards=all&pretty&s=index" \
    #     -H "Content-Type: application/json")
    response="$(send_get_all_indices_request)"

    echo
    # We need to use sed in order to delete the first line which contains the column headers.
    # wc is designed to handle multiple inputs and align the output for readability when processing
    # multiple files or inputs simultaneously. Even when processing a single input, it maintains this
    # formatting for consistency and therefore the output number is padded with spaces. awk is added
    # to remove the padding and print only the number.
    echo "Total number of indices: $(echo "$response" | sed '1d' | wc -l | awk '{print $1}')"
    echo

    # Use double quotes to preserve newlines
    echo "$response"

    echo
    echo "List of index names only:"
    echo
    echo "$response" | awk '{print $3}'
    echo

    # Show non-hidden indices only
    echo
    echo "List of non-hidden index names only:"
    echo
    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/indices?v&expand_wildcards=open,closed&h=index,status&s=index" \
        -H "Content-Type: application/json"

    # Show hidden indices only
    echo
    echo "List of hidden index names only:"
    echo
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/indices?v&expand_wildcards=hidden&h=index,status&s=index" \
        -H "Content-Type: application/json")

    # check if response is in json format
    if [[ "$response" == *"{"* ]]; then
        echo "$response" | jq .
    else
        echo "$response"
    fi
}

# | jq -r '.indices | to_entries[] | select(.value.step == "ERROR") | .key'
show_indices_with_ilm_errors_detailed() {
    echo
    echo "Fetching indices with ILM errors..."

    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/.*,*/_ilm/explain?only_managed=false&pretty&only_errors=true"
}

#  | jq -r '.indices | keys[]'
#
#
# _all/_ilm/explain returns information about the index lifecycle management (ILM) state of indices.
# _all - return information about all indices and data streams. (We can also use * instead of _all)
#
# By default, it only returns information for indices managed by ILM. Indices not managed by ILM are excluded.
# To ensure all indices are included in the response: Use the "only_managed" parameter set to false:
#   GET _all/_ilm/explain?only_managed=false
# By default, _all does not include hidden indices. Elasticsearch treats hidden indices separately,
# so we need to request them specifically using .*,*. To include hidden indices in the response:
#   GET /.*,*/_ilm/explain?only_managed=false
#
# see: https://www.elastic.co/guide/en/elasticsearch/reference/current/ilm-explain-lifecycle.html
#
# JSON response looks like this:
#
# {
#   "indices": {
#     ".ds-metrics-apm.service_summary.1m-default-2024.07.10-000061": {
#       "index": ".ds-metrics-apm.service_summary.1m-default-2024.07.10-000061",
#       "managed": true,
#       "policy": "metrics-apm.service_summary_interval_metrics-default_policy.1m",
#       "index_creation_date_millis": 1720635391266,
#       "time_since_index_creation": "237.68d",
#       "lifecycle_date_millis": 1721240791309,
#       "age": "230.67d",
#       "phase": "hot",
#       "phase_time_millis": 1720635391794,
#       "action": "complete",
#       "action_time_millis": 1721240793509,
#       "step": "complete",
#       "step_time_millis": 1721240793509,
#       "step_info": {
#         "type": "illegal_state_exception",
#         "reason": "unable to parse steps for policy [metrics-apm.service_summary_interval_metrics-default_policy.1m] as it doesn't exist"
#       },
#       "phase_execution": {
#         "policy": "metrics-apm.service_summary_interval_metrics-default_policy.1m",
#         "phase_definition": {
#           "min_age": "0ms",
#           "actions": {
#             "rollover": {
#               "max_age": "7d",
#               "min_docs": 1,
#               "max_primary_shard_docs": 200000000,
#               "max_size": "50gb"
#             },
#             "set_priority": {
#               "priority": 100
#             }
#           }
#         },
#         "version": 2,
#         "modified_date_in_millis": 1685469225597
#       }
#     },

# !!!!!!!!
# WARNING: It is assumed that request was sent with -w "%{http_code}".
# !!!!!!!!
# Input:
# response - raw response from curl command
# is_json_expected - true if response is expected to be in JSON format
# Output error code: 0 if success, 1 if error
# Output data: response body (JSON)
process_response() {
    local response="$1"
    local is_json_expected="$2"

    if [[ -z "$response" ]]; then
        log_error "Empty response."
        return 1
    fi

    # Extract the HTTP status code from the response (last 3 characters)
    http_status_code="${response: -3}"
    # Extract the JSON response (everything except the last 3 characters)
    response_body="${response:0:${#response}-3}"
    # response_body="${response::-3}"

    if [[ "$http_status_code" -ne 200 ]]; then
        log_error "Request failed. HTTP status code: $http_status_code"
        log_error "Response body: $response_body"
        return 1
    fi

    if [[ "$is_json_expected" == "true" ]]; then
        # check if response is in json format
        if [[ "$response_body" != *"{"* ]]; then
            log_error "Response is not in JSON format. HTTP status code: $http_status_code"
            log_error "Response body: $response_body"
            return 1
        fi
    fi

    printf "%s" "$response_body"
}

show_indices_with_ilm_errors() {
    log_wait "Fetching indices with ILM errors..."

    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/.*,*/_ilm/explain?only_managed=false&pretty&only_errors=true" \
        -H "Content-Type: application/json")

    local response_body
    if ! response_body=$(process_response "$response" true); then
        log_error "Request failed"
        return 1
    fi

    # If there are no indices with ILM errors, response body looks like this:
    # {
    # "indices" : { }
    # }
    # Check if there are no indices with ilm errors
    if [[ "$response_body" == *"\"indices\" : { }"* ]]; then
        log_info "No indices with ILM errors found."
        return 0
    fi

    echo "$response_body" | jq -r \
    '
        .indices |
        to_entries[] |
        .value.index + "\n" +
        "\tReason: " + .value.step_info.reason + "\n"
    '
}

show_aliases_for_index() {
    local index="$1"

    echo
    echo "Fetching aliases for index: $index..."

    # Get all aliases
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_aliases?pretty"
    )

    aliases=$(echo "$response" | jq --arg index "$index" '.[$index].aliases? | select(. != null and . != {}) | keys[]')
    if [[ -z "$aliases" ]]; then
        echo "No aliases found."
    else
        echo "Aliases: "
        echo "$aliases" | jq .
    fi
}

# _data_stream/_all?pretty returns data like this:
#
# {
#   "data_streams": [
#     {
#       "name": "logs-apm.app-default",
#       "timestamp_field": {
#         "name": "@timestamp"
#       },
#       "indices": [
#         {
#           "index_name": ".ds-logs-apm.app-default-2025.02.09-000013",
#           "index_uuid": "6a1oBak9QcOlODTEqYakgg",
#           "prefer_ilm": true,
#           "ilm_policy": "logs-apm.app_logs-default_policy",
#           "managed_by": "Index Lifecycle Management"
#         }
#       ],
#       "generation": 25,
#       "_meta": {
#         "package": {
#           "name": "apm"
#         },
#         "managed_by": "fleet",
#         "managed": true
#       },
#       "status": "GREEN",
#       "template": "logs-apm.app",
#       "ilm_policy": "mycorp-logs@custom",
#       "next_generation_managed_by": "Index Lifecycle Management",
#       "prefer_ilm": true,
#       "hidden": false,
#       "system": false,
#       "allow_custom_routing": false,
#       "replicated": false,
#       "rollover_on_write": false
#     },
show_data_stream_for_index() {
    local index="$1"

    echo
    echo "Fetching data streams for index: $index..."

    # Get all data streams
    local response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream?pretty&expand_wildcards=all"
    )

    local data_streams=$(echo "$response" | jq --arg index "$index" '.data_streams[] | select(.indices[].index_name == $index) | .name')

    if [[ -z "$data_streams" ]]; then
        echo "No data streams found."
    else
        echo "Data streams: "
        echo "$data_streams"
    fi
}

show_index_details() {
    local index_name=""

    echo >&2
    echo "Show index/indices details" >&2
    echo >&2

    # Prompt user for index name
    read -e -r -p "Enter index name (use wildcards to match multiple indices): " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        return 1
    fi

    echo "Finding index (using CAT API): $index_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/indices/$index_name?v&expand_wildcards=all&pretty" \
        -H 'Content-Type: application/json')

    echo
    echo "$response"

    # Fetch and show index settings

    echo
    echo "Index settings:"
    echo

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_settings?pretty" \
        -H 'Content-Type: application/json')
    echo "$response" | jq .

    # Check if $index_name contains wildcards
    if [[ "$index_name" == *"*"* ]]; then
        echo
        echo "Index name contains wildcards. Skipping further details."
        return 0
    fi

    local creation_date=$(echo "$response" | jq -r '.[].settings.index.creation_date')
    echo
    echo "Human readable creation date:" $(date -r $(($creation_date/1000)) "+%Y-%m-%d %H:%M:%S %Z")
    echo

    show_templates_for_index "$index_name"

    show_aliases_for_index "$index_name"

    show_data_stream_for_index "$index_name"

    show_index_ilm_details "$index_name"
}

show_data_stream() {
    local data_stream_name=""
    echo >&2
    echo "Show data stream details" >&2
    echo >&2

    # Prompt user for data stream name
    read -e -r -p "Enter data stream name: " data_stream_name

    if [[ -z "$data_stream_name" ]]; then
        echo "Data stream name is required!"
        return 1
    fi

    echo "Finding data stream: $data_stream_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/$data_stream_name?pretty" \
        -H 'Content-Type: application/json')

    echo
    echo "$response" | jq .

    local status=$(echo "$response" | jq -r '.data_streams[0].status')
    echo
    echo "Data stream status: $status"

    local is_managed=$(echo "$response" | jq -r '.data_streams[0]._meta.managed')
    echo
    echo "Data stream is managed: $is_managed"

    local generation=$(echo "$response" | jq -r '.data_streams[0].generation')
    echo
    echo "Data stream generation: $generation"

    local documents_count=$(show_documents_count "$data_stream_name" | jq -r '.count')
    echo
    echo "Number of documents in data stream: $documents_count"

    # echo
    # echo "Currently active (write) backing index for this data stream is the latest index."
    show_data_stream_ilm_status "$data_stream_name"

    # response=$(curl \
    #     -s \
    #     -u "$ES_USERNAME:$ES_PASSWORD" \
    #     -X GET \
    #     "$ES_HOST/_data_stream/$data_stream_name?human=true" \
    #     -H 'Content-Type: application/json')
    # echo
    # echo "$response" | jq .

    # Fetch and show data stream backing indices
    echo
    show_supporting_indices_for_data_stream "$data_stream_name"

    echo
    echo "Supporting index and component templates:"
    echo
    local data_streams=("$data_stream_name")
    show_templates_for_data_streams "${data_streams[@]}"
}

# PUT /_data_stream/<data_stream_name> API does not accept a body when creating a data stream.
# When creating a data stream, you only need to specify the name of the data stream, and
# Elasticsearch will automatically associate it with the appropriate index templates and settings.
# For managed data streams, Elasticsearch expects that the index template and ILM policy are
# already in place, and it will automatically handle the rest of the configuration.
create_data_stream() {
    local data_stream_name=""

    read -e -r -p "Enter data stream name: " data_stream_name
    if [[ -z "$data_stream_name" ]]; then
        echo "Data stream name is required!"
        return 1
    fi

    echo "Creating data stream: $data_stream_name..."
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X PUT \
        "$ES_HOST/_data_stream/$data_stream_name?pretty" \
        -H 'Content-Type: application/json'
    )

    echo
    echo "$response" | jq .
}

show_documents_in_data_stream(){
    local data_stream_name=""
    local documents_count=10

    echo >&2
    echo "Data stream content" >&2
    echo >&2

    # Prompt user for data stream name
    read -e -r -p "Enter data stream name: " data_stream_name

    if [[ -z "$data_stream_name" ]]; then
        echo "Data stream name is required!"
        return 1
    fi

    echo "Fetching number of documents in data stream: $data_stream_name..." >&2

    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/$data_stream_name/_count?pretty=true" \
         -H 'Content-Type: application/json' \
         -d \
         '{
            "query": {
                "match_all": {}
            }
        }'

    read -e -r -p "Enter how many documents to fetch from the data stream (default is 10): " documents_count

    if [[ -z "$documents_count" ]]; then
        documents_count=10
    fi

    # Ask user if they want to fetch the latest or oldest documents
    local sort_order=""
    read -e -r -p "Enter sort order (asc/desc): " sort_order
    if [[ -z "$sort_order" ]]; then
        sort_order="desc"
    fi

    echo "Fetching $documents_count documents in sort order $sort_order from data stream: $data_stream_name..." >&2

    # Fetch and show latest $documents_count documents in data stream
    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/$data_stream_name/_search?size=$documents_count&pretty=true" \
         -H 'Content-Type: application/json' \
         -d \
        '{
            "sort": [
                {
                    "@timestamp": {
                        "order": "'"$sort_order"'"
                    }
                }
            ]
        }'
}

# TransportRolloverAction executes only one cluster state update that:
# 1) creates the new (rollover index)
# 2) rolls over the alias from the source to the target index
# 3) sets the RolloverInfo on the source index.
#
# Example response in case of successful rollover of data stream <data_stream_name>:
# {
#   "acknowledged": true,
#   "shards_acknowledged": true,
#   "old_index": ".ds-<data_stream_name>-2025.02.28-000047",
#   "new_index": ".ds-<data_stream_name>-2025.03.10-000094",
#   "rolled_over": true,
#   "dry_run": false,
#   "lazy": false,
#   "conditions": {}
# }
rollover_data_stream(){
    local data_stream_name=""
    echo >&2
    echo "Rollover data stream" >&2
    echo >&2

    # Prompt user for data stream name
    read -e -r -p "Enter data stream name: " data_stream_name

    if [[ -z "$data_stream_name" ]]; then
        echo "Data stream name is required!"
        return 1
    fi

    echo "Rollover data stream: $data_stream_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/$data_stream_name/_rollover?pretty" \
        -H 'Content-Type: application/json')

    echo
    echo "$response" | jq .
}

add_index_to_data_stream() {
    local data_stream_name="$1"
    local index_name="$2"
    log_info "Add index to data stream"

    if [[ -z "$data_stream_name" ]]; then
        data_stream_name=$(prompt_user_for_value "data stream name")
        log_info "Data stream name: $data_stream_name"
    fi

    if [[ -z "$index_name" ]]; then
        index_name=$(prompt_user_for_value "index name")
        log_info "Index name: $index_name"
    fi

    log_info "Adding index $index_name to data stream $data_stream_name..." >&2

    # double quotes are required for variable expansion
    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/_data_stream/_modify" \
        -H "Content-Type: application/json" \
        -d \
        '{
            "actions": [
                {
                    "add_backing_index": {
                        "data_stream": "'"$data_stream_name"'",
                        "index": "'"$index_name"'"
                    }
                }
            ]
        }')

    local response_body
    if ! response_body=$(process_response "$response" true); then
        log_error "Request failed"
        return 1
    fi

    echo "$response_body" | jq . >&2
}

remove_index_from_data_stream() {
    local data_stream_name=""
    local index_name=""

    log_info "Remove index from data stream"

    read -e -r -p "Enter data stream name: " data_stream_name

    if [[ -z "$data_stream_name" ]]; then
        log_error "Data stream name is required!"
        return 1
    fi

    read -e -r -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        log_error "Index name is required!"
        return 1
    fi

    log_info "Removing index $index_name from data stream $data_stream_name..."

    # double quotes are required for variable expansion
    local response
    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/_data_stream/_modify" \
        -H "Content-Type: application/json" \
        -d \
        '{
            "actions": [
                {
                    "remove_backing_index": {
                        "data_stream": "'"$data_stream_name"'",
                        "index": "'"$index_name"'"
                    }
                }
            ]
        }')

    log_debug "Response HTTP code: $http_code"

    # Check if response is JSON
    if [[ "$response" == *"{"* ]]; then
         echo "$response" | jq .
    else
        # If response is not JSON, print it as is
        echo "$response"
    fi
}

get_ilm_policy_for_data_stream() {
    local data_stream_name=$1

    if [[ -z "$data_stream_name" ]]; then
        if ! data_stream_name=$(prompt_user_for_value "data stream name"); then
            log_error "Data stream name is required!"
            return 1
        fi
    fi

    log_info "Fetching ILM policy for data stream: $data_stream_name..."

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/$data_stream_name?pretty" \
        -H 'Content-Type: application/json')

    ilm_policy=$(echo "$response" | jq -r '.data_streams[0].ilm_policy')
    printf "%s" "$ilm_policy"
}

get_index_template_for_data_stream() {
    local data_stream_name=$1
   
    if [[ -z "$data_stream_name" ]]; then
        if ! data_stream_name=$(prompt_user_for_value "data stream name"); then
            log_error "Data stream name is required!"
            return 1
        fi
    fi

    # if [[ -z "$data_stream_name" ]]; then
    #     read -r -p "Enter data stream name: " data_stream_name
    #     if [[ -z "$data_stream_name" ]]; then
    #         echo "Data stream name is required!"
    #         return 1
    #     fi
    # fi

    log_info "Fetching index template for data stream: $data_stream_name..."

    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/$data_stream_name?pretty" \
        -H 'Content-Type: application/json')

    local response_body
    if ! response_body=$(process_response "$response" true); then
        log_error "Request failed"
        return 1
    fi

    index_template=$(echo "$response_body" | jq -r '.data_streams[0].template')
    log_success "Found index template for data stream $data_stream_name: $index_template"
    printf "%s" "$index_template"
}

get_default_pipeline_for_index_template() {
    local index_template_name=$1
    
    if [[ -z "$index_template_name" ]]; then
        if ! index_template_name=$(prompt_user_for_value "index template name"); then
            log_error "Index template name is required!"
            return 1
        fi
    fi

    log_info "Fetching default pipeline for index template: $index_template_name..."

    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template/$index_template_name?pretty" \
        -H 'Content-Type: application/json')

    local response_body
    if ! response_body=$(process_response "$response" true); then
        log_error "Request failed"
        return 1
    fi

    default_pipeline=$(echo "$response_body" | jq -r \
    '.index_templates[0].index_template.template.settings.index.default_pipeline')
    echo "$default_pipeline"
}

get_final_pipeline_for_index_template() {
    local index_template_name=$1

    if [[ -z "$index_template_name" ]]; then
        if ! index_template_name=$(prompt_user_for_value "index template name"); then
            log_error "Index template name is required!"
            return 1
        fi
    fi

    log_info "Fetching final pipeline for index template: $index_template_name..."

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template/$index_template_name?pretty" \
        -H 'Content-Type: application/json')

    final_pipeline=$(echo "$response" | jq -r '.index_templates[0].index_template.template.settings.index.final_pipeline')
    echo "$final_pipeline"
}

get_default_pipeline_for_data_stream() {
    local data_stream_name=$1

    if [[ -z "$data_stream_name" ]]; then
        if ! data_stream_name=$(prompt_user_for_value "data stream name"); then
            log_error "Data stream name is required!"
            return 1
        fi
    fi

    log_info "Fetching default pipeline for data stream: $data_stream_name..."

    local index_template
    index_template=$(get_index_template_for_data_stream "$data_stream_name")

    local default_pipeline
    default_pipeline=$(get_default_pipeline_for_index_template "$index_template")
    log_info "Default pipeline for data stream $data_stream_name: $default_pipeline"
    echo "$default_pipeline"
}

get_final_pipeline_for_data_stream() {
    local data_stream_name=$1

    if [[ -z "$data_stream_name" ]]; then
        if ! data_stream_name=$(prompt_user_for_value "data stream name"); then
            log_error "Data stream name is required!"
            return 1
        fi
    fi

    log_info "Fetching final pipeline for data stream: $data_stream_name..." >&2
    local index_template
    index_template=$(get_index_template_for_data_stream "$data_stream_name")
    local final_pipeline
    final_pipeline=$(get_final_pipeline_for_index_template "$index_template")
    log_info "Final pipeline for data stream $data_stream_name: $final_pipeline" >&2
    echo "$final_pipeline"
}

# Before the index gets assigned a new ILM policy, we need to remove the index
# from the ILM management completely as otherwise we'll have situation like below
# where policy is set to a new one but phase_execution.policy is set to the original
# ILM policy.
#
# Before removing ILM policy from an index
# ".ds-metrics-apm.app.example_api-default-2023.04.17-000001": {
#   "index": ".ds-metrics-apm.app.example_api-default-2023.04.17-000001",
#   "managed": true,
#   "policy": "mycorp-metrics-apm-custom_policy",
#   "index_creation_date_millis": 1681741950598,
#   "time_since_index_creation": "714.39d",
#   "lifecycle_date_millis": 1684334206714,
#   "age": "684.39d",
#   "phase": "hot",
#   "phase_time_millis": 1681741950818,
#   "action": "complete",
#   "action_time_millis": 1684334207314,
#   "step": "complete",
#   "step_time_millis": 1684334207314,
#   "phase_execution": {
#     "policy": "metrics-apm.app_metrics-default_policy",
#     "phase_definition": {
#       "min_age": "0ms",
#       "actions": {
#         "rollover": {
#           "max_age": "30d",
#           "min_docs": 1,
#           "max_primary_shard_docs": 200000000,
#           "max_size": "50gb"
#         },
#         "set_priority": {
#           "priority": 100
#         }
#       }
#     },
#     "version": 2,
#     "modified_date_in_millis": 1685469007995
#   }
# },
#
# After removing ILM policy from an index:
#
# ".ds-metrics-apm.app.example_api-default-2023.04.17-000001": {
#   "index": ".ds-metrics-apm.app.example_api-default-2023.04.17-000001",
#   "managed": true,
#   "policy": "mycorp-metrics-apm-custom_policy",
#   "index_creation_date_millis": 1681741950598,
#   "time_since_index_creation": "714.41d",
#   "lifecycle_date_millis": 1681741950598,
#   "age": "714.41d",
#   "phase": "hot",
#   "phase_time_millis": 1743467336696,
#   "action": "rollover",
#   "action_time_millis": 1743467336896,
#   "step": "check-rollover-ready",
#   "step_time_millis": 1743467336896,
#   "phase_execution": {
#     "policy": "mycorp-metrics-apm-custom_policy",
#     "phase_definition": {
#       "min_age": "0ms",
#       "actions": {
#         "rollover": {
#           "max_age": "30d",
#           "min_docs": 1,
#           "max_primary_shard_docs": 200000000,
#           "max_primary_shard_size": "50gb"
#         }
#       }
#     },
#     "version": 1,
#     "modified_date_in_millis": 1743014219299
#   }
# },
remove_ilm_policy_from_index() {
    local index_name=$1
    local http_code

    if [[ -z "$index_name" ]]; then
        index_name=$(prompt_user_for_value "index name")
    fi
    
    log_info "Removing ILM policy from index $index_name..."

    # double quotes are required for variable expansion
    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/$index_name/_ilm/remove" \
        -H "Content-Type: application/json")

    # Extract the HTTP status code from the response
    # http_code=$(echo "$response" | tail -n1)
    http_code="${response: -3}"

    # Extract the response body
    # Remove the last 3 characters from the response to get the body
    response_body="${response:: -3}"

    # Check if the http code is 200
    if [[ "$http_code" -eq 200 ]]; then
        log_info "Response HTTP code: $http_code"

        # Check if response is JSON
        if [[ "$response_body" == *"{"* ]]; then
            log_info "Response body:\n$(echo "$response_body" | jq .)"
        else
            log_error "Response is not in JSON format."
            log_error "Response body:\n$response_body"
        fi
    else
        log_error "Failed to remove ILM policy from index $index_name. HTTP code: $http_code"

        # Check if response is JSON
        if [[ "$response_body" == *"{"* ]]; then
            log_error "Response body:\n$(echo "$response_body" | jq .)"
        else
            log_error "Response body:\n$response_body"
        fi
    fi
}

set_ilm_policy_for_index() {
    local index_name=$1
    local ilm_policy=$2

    if [[ -z "$index_name" ]]; then
       if ! index_name=$(prompt_user_for_value "index name"); then
            log_error "Index name is required!"
            return 1
        fi
    fi

    if [[ -z "$ilm_policy" ]]; then
        if ! ilm_policy=$(prompt_user_for_value "ilm policy"); then
            log_error "ILM policy is required!"
            return 1
        fi
    fi

    log_info "Setting ILM policy $ilm_policy for index $index_name..."

    # double quotes are required for variable expansion
    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X PUT \
        "$ES_HOST/$index_name/_settings?pretty" \
        -H "Content-Type: application/json" \
        -d \
        '{
            "index": {
                "lifecycle.name": "'"$ilm_policy"'"
            }
        }')

    local response_body
    if ! response_body=$(process_response "$response" true); then
        log_error "Request failed"
        return 1
    fi

    echo "$response_body" | jq .
}

set_default_pipeline_for_index() {
    local index_name=$1
    local default_pipeline=$2

    if [[ -z "$index_name" ]]; then
        if ! index_name=$(prompt_user_for_value "index name"); then
            log_error "Index name is required!"
            return 1
        fi
    fi

    if [[ -z "$default_pipeline" ]]; then
        if ! default_pipeline=$(prompt_user_for_value "default pipeline"); then
            log_error "Default pipeline is required!"
            return 1
        fi
    fi

    log_info "Setting default pipeline $default_pipeline for index $index_name..."

    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X PUT \
        "$ES_HOST/$index_name/_settings?pretty" \
        -H "Content-Type: application/json" \
        -d \
        '{
            "index": {
                "default_pipeline": "'"$default_pipeline"'"
            }
        }')

    local response_body
    if ! response_body=$(process_response "$response" true); then
        log_error "Request failed"
        return 1
    fi

    echo "$response_body" | jq .
}

set_final_pipeline_for_index() {
    local index_name=$1
    local final_pipeline=$2

    if [[ -z "$index_name" ]]; then
        if ! index_name=$(prompt_user_for_value "index name"); then
            log_error "Index name is required!"
            return 1
        fi
    fi

    if [[ -z "$final_pipeline" ]]; then
        if ! final_pipeline=$(prompt_user_for_value "final pipeline"); then
            log_error "Final pipeline is required!"
            return 1
        fi
    fi

    log_info "Setting final pipeline $final_pipeline for index $index_name..."

    # double quotes are required for variable expansion
    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X PUT \
        "$ES_HOST/$index_name/_settings?pretty" \
        -H "Content-Type: application/json" \
        -d \
        '{
            "index": {
                "final_pipeline": "'"$final_pipeline"'"
            }
        }')

    local response_body
    if ! response_body=$(process_response "$response" true); then
        log_error "Request failed"
        return 1
    fi

    echo "$response_body" | jq .
}

get_backing_indices_for_data_stream() {
    local data_stream_name=$1

    if [[ -z "$data_stream_name" ]]; then
        data_stream_name=$(prompt_user_for_value "data stream name")
    fi

    echo "Fetching backing indices for data stream: $data_stream_name..." >&2

    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/$data_stream_name?pretty" \
        -H 'Content-Type: application/json')

    # Extract the HTTP status code from the response
    # http_code=$(echo "$response" | tail -n1)
    http_code="${response: -3}" # Extract the last 3 characters (HTTP code)
    # log_info "HTTP code: $http_code"

    # Extract the response body
    # response_body=$(echo "$response" | head -n -1)
    response_body="${response::-3}" # Extract everything except the last 3 characters (response body)

    # Check if the http code is 200
    if [[ "$http_code" -eq 200 ]]; then
        log_info "Response HTTP code: $http_code"

        # Check if response is JSON
        if [[ "$response_body" == *"{"* ]]; then
            # Extract the backing indices from the response
            backing_indices=$(echo "$response_body" | jq -r '.data_streams[0].indices[].index_name')
            log_debug "Backing indices:\n$backing_indices"
        else
            log_error "Failed to fetch backing indices. Response is not JSON."
            log_error "Response body: $response_body"
            return 1
        fi
    else
        log_error "Failed to fetch backing indices for data stream $data_stream_name. HTTP code: $http_code"
        log_error "Response body: $response_body"
        return 1
    fi

    printf "%s" "$backing_indices"
}

get_detached_backing_indices_for_data_stream(){
    local data_stream_name=$1

    if [[ -z "$data_stream_name" ]]; then
        read -e -r -p "Enter data stream name: " data_stream_name
        if [[ -z "$data_stream_name" ]]; then
            log_error "Data stream name is required!"
            return 1
        fi
    fi

    log_info "Fetching detached backing indices for data stream: $data_stream_name..."

    # Find all indices whose name matches the data stream name (.ds-<data_stream_name>-*) but which are not attached to the data stream
    # Example output:
    # green open .ds-metrics-apm.app.example_api-default-2023.04.17-000001 ol1Li2hcTTe-bYGh3Ap0mA 1 1 20315 0 10.2mb 5.1mb 5.1mb
    # Alternatively, we can use:
    # # "/_cat/indices?v&expand_wildcards=all&h=index,status&s=index"  | grep ".ds-$data_stream_name-"
    local index_name_pattern=".ds-${data_stream_name}-*"
    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/indices/$index_name_pattern" \
        -H 'Content-Type: application/json')

    local response_body
    if ! response_body=$(process_response "$response" false); then
        log_error "Request failed"
        return 1
    fi

    # IMPORTANT:
    # GET _cat/indices/.ds-<non_existant_data_stream_>-* returns 200 - OK and EMPTY body
    # That's why we also need to check if the response body is empty:
    if [[ -z "$response_body" ]]; then
        log_warning "No indices with name $index_name_pattern found."
        return 0
    fi

    matching_indices=$(printf "%s" "$response_body" | awk '{print $3}')
    log_info "matching_indices:\n$matching_indices"

    attached_indices=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/$data_stream_name?pretty" \
        -H 'Content-Type: application/json' | jq -r '.data_streams[0].indices[].index_name')
    log_info "attached_indices:\n$attached_indices"

    # Find indices that are not attached to the data stream
    # Echo by default adds a new line at the end, so we can use printf to format the output
    detached_backing_indices=$(printf "%s" "$matching_indices" | grep -v "$attached_indices")
    # log_info "detached_backing_indices: $detached_backing_indices"
    # log_info "Number of detached backing indices: $(printf "%s" "$detached_backing_indices" | wc -l)"

    printf "%s" "$detached_backing_indices"

    # for index in $matching_indices; do
    #     if ! echo "$attached_indices" | grep -q "$index"; then
    #         echo "Unattached index: $index"
    #     fi
    # done
}

fix_backing_indices_ilm_policies_and_pipelines(){
    local data_stream_name="$1"

    if [[ -z "$data_stream_name" ]]; then
        data_stream_name=$(prompt_user_for_value "data stream name")
    fi

    log_info "Fixing backing indices for data stream $data_stream_name..." >&2

    # Get ILM policy for data stream
    local ilm_policy
    ilm_policy=$(get_ilm_policy_for_data_stream "$data_stream_name")
    log_success "Found ILM policy for data stream $data_stream_name: $ilm_policy"

    # Get default pipeline for data stream
    local default_pipeline
    default_pipeline=$(get_default_pipeline_for_data_stream "$data_stream_name")
    if [[ "$default_pipeline" == "null" ]]; then
        log_warning "Default pipeline for data stream $data_stream_name: $default_pipeline"
    else
        log_success "Found default pipeline for data stream $data_stream_name: $default_pipeline"
    fi

    # Get final pipeline for data stream
    local final_pipeline
    final_pipeline=$(get_final_pipeline_for_data_stream "$data_stream_name")

    if [[ "$final_pipeline" == "null" ]]; then
        log_warning "Final pipeline for data stream $data_stream_name: $final_pipeline"
    else
        log_success "Found final pipeline for data stream $data_stream_name: $final_pipeline"
    fi

    # Iterate through backing indices and set ILM policy and pipelines
    local backing_indices

    # Use mapfile to assign the output to an array
    local ret_val
    
    if ! ret_val=$(get_backing_indices_for_data_stream "$data_stream_name"); then
        log_error "Failed to get backing indices for data stream: $data_stream_name"
        return 1
    fi

    # Read the output into an array
    mapfile -t backing_indices <<< "$ret_val"
    # log_info "backing_indices: ${backing_indices[*]}"

    if [[ ${#backing_indices[@]} -eq 0 ]]; then
        log_warning "No backing indices found for data stream: $data_stream_name"
        return 0
    fi

    for index in "${backing_indices[@]}"; do
        log_info "Aligning ILM policy for backing index: $index..."
        remove_ilm_policy_from_index "$index"
        set_ilm_policy_for_index "$index" "$ilm_policy"
        set_default_pipeline_for_index "$index" "$default_pipeline"
        set_final_pipeline_for_index "$index" "$final_pipeline"
    done
}

attach_detached_backing_indices_to_data_stream() {
    local data_stream_name="$1"

    if [[ -z "$data_stream_name" ]]; then
        read -e -r -p "Enter data stream name: " data_stream_name
        if [[ -z "$data_stream_name" ]]; then
            log_error "Data stream name is required!"
            return 1
        fi
    fi

    # Get detached backing indices
    # Use mapfile to assign the output to an array
    local detached_backing_indices=()
    local ret_val
    
    if ! ret_val=$(get_detached_backing_indices_for_data_stream "$data_stream_name"); then
        log_error "Failed to get detached backing indices for data stream: $data_stream_name"
        return 1
    fi

    if [[ -z "$ret_val" ]]; then
        log_info "No detached backing indices found for data stream: $data_stream_name"
        return 0
    fi

    mapfile -t detached_backing_indices <<< "$ret_val"
    # log_info "Number of detached backing indices: ${#detached_backing_indices[@]}"

    # Check if there are any detached backing indices
    if [[ ${#detached_backing_indices[@]} -eq 0 ]]; then
        log_info "No detached backing indices found for data stream: $data_stream_name"
        return 0
    fi

    for index in "${detached_backing_indices[@]}"; do
        log_info "Attaching detached backing index: $index to data stream: $data_stream_name..."
        add_index_to_data_stream "$data_stream_name" "$index"
    done

    echo "${detached_backing_indices[@]}"
}

fix_backing_index_rollover_info() {
    # Get ILM details for index and extract the following fields of current step:
    # - phase
    # - action
    # - name

    local index_name="$1"
    if [[ -z "$index_name" ]]; then
        index_name=$(prompt_user_for_value "index name")
        log_info "Index name: $index_name"
    fi

    local response
    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_ilm/explain?pretty" \
        -H 'Content-Type: application/json')

    local response_body
    if ! response_body=$(process_response "$response" true); then
        log_error "Request failed"
        return 1
    fi

    # Extract the current phase, action and step name
    local current_phase
    local current_action
    local current_step_name

    current_phase=$(echo "$response_body" | jq -r '.indices | to_entries[0].value.phase')
    current_action=$(echo "$response_body" | jq -r '.indices | to_entries[0].value.action')
    current_step_name=$(echo "$response_body" | jq -r '.indices | to_entries[0].value.step')

    log_info "Current phase: $current_phase"
    log_info "Current action: $current_action"
    log_info "Current step name: $current_step_name"

    # Move index to ILM step
    local next_phase="hot"
    local next_action="rollover"
    # local next_step_name="check-rollover-ready"
    local next_step_name="set-indexing-complete"

    log_info "Moving index: $index_name to ILM step (phase): $next_phase..."
    local post_data="{
        \"current_step\": {
            \"phase\": \"$current_phase\",
            \"action\": \"$current_action\",
            \"name\": \"$current_step_name\"
        },
        \"next_step\": {
            \"phase\": \"$next_phase\",
            \"action\": \"$next_action\",
            \"name\": \"$next_step_name\"
        }
    }"
    log_info "Post data: " >&2
    log_info "$post_data" >&2
    printf "❓ Do you want to proceed? (y/n): "
    read -e -r confirm
    if [[ "$confirm" != "y" ]]; then
        log_info "Moving index to ILM step cancelled."
        return 0
    fi
    # Send the request to move the index to the next ILM step
    response=$(curl \
        -s \
        -w "%{http_code}" \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/_ilm/move/$index_name?pretty" \
        -H "Content-Type: application/json" \
        -d "$post_data")

    local response_body
    if ! response_body=$(process_response "$response" true); then
        log_error "Request failed"
        return 1
    fi
    
    # Print the response body
    log_info "Response body:\n$response_body" >&2
}


# Arguments:
# $1 - data stream name
# $2 - is_interactive (optional, default: true)
# This function is used to fix ILM policies and pipelines for a data stream.
# It prompts the user for confirmation before proceeding with the fix.
fix_backing_indices() {
    local data_stream_name="$1"
    local is_interactive="$2"

    if [[ -z "$data_stream_name" ]]; then
        data_stream_name=$(prompt_user_for_value "data stream name")
        log_info "Data stream: $data_stream_name"
    fi

    log_info "Fixing backing indices for data stream: $data_stream_name..." >&2

    if [[ -z "$is_interactive" ]]; then
        is_interactive="true"
    fi

    log_debug "is_interactive: $is_interactive"

    local include=true
    if [[ "$is_interactive" == "true" ]]; then
        include=$(prompt_user_for_confirmation "❓ Do you want to fix ILM policies and pipelines?" "n")
    fi

    if [[ "$include" == "true" ]]; then
        fix_backing_indices_ilm_policies_and_pipelines "$data_stream_name"
    else
        log_info "Skipping fixing ILM policies and pipelines..."
    fi

    local attached_indices=()
    include=true
    if [[ "$is_interactive" == "true" ]]; then
        include=$(prompt_user_for_confirmation "❓ Do you want to attach detached backing indices to data stream?" "n")
    fi

    if [[ "$include" == "true" ]]; then
        mapfile -t attached_indices < <(attach_detached_backing_indices_to_data_stream "$data_stream_name")
        log_info "Attached indices: ${attached_indices[*]}"
    else
        log_info "Skipping attaching detached backing indices..."
        return 0
    fi

    if [[ ${#attached_indices[@]} -eq 0 ]]; then
        log_warning "No attached indices found."
        return 0
    fi

    include=true
    if [[ "$is_interactive" == "true" ]]; then
        include=$(prompt_user_for_confirmation "❓ Do you want to fix rollover info for attached indices?" "n")
    fi

    if [[ "$include" == "true" ]]; then
        for index in "${attached_indices[@]}"; do
            log_info "Fixing rollover info for index: $index..."
            fix_backing_index_rollover_info "$index"
        done
    else
        log_info "Skipping fixing rollover info..."
    fi
}

fix_backing_indices_multiple_streams() {
    local data_streams=()
    local data_stream_names=""

    printf "❓ Enter data stream names (comma separated): "
    read -e -r data_stream_names

    if [[ -z "$data_stream_names" ]]; then
        log_error "Data stream names are required!"
        return 1
    fi

    # Split the input into an array
    IFS=',' read -r -a data_streams <<< "$data_stream_names"

    for ds in "${data_streams[@]}"; do
        fix_backing_indices "$ds"
    done
}

# This function is an automated, non-interactive version of the
# fix_backing_indices_multiple_streams function. User only needs to
# provide the name of the snapshot that was restored last.
fix_backing_indices_snapshot_streams() {
    local snapshot_repository
    if ! snapshot_repository=$(prompt_user_to_select_snapshot_repository); then
        log_error "Failed to select snapshot repository!"
        return 1
    fi
    log_info "Selected snapshot repository: $snapshot_repository"

    # Prompt user for snapshot name
    log_empty_line
    local snapshot_name=""
    printf "❓ Enter snapshot name: "
    read -e -r snapshot_name
    if [[ -z "$snapshot_name" ]]; then
        log_error "Snapshot name is required!"
        return 1
    fi
    log_debug "Snapshot name: $snapshot_name..."

    # Get the list of data streams from the snapshot
    log_empty_line
    local ret_val
    if ! ret_val=$(get_data_streams_from_snapshot "$snapshot_repository" "$snapshot_name"); then
        log_error "Failed to get data streams from snapshot: $snapshot_name"
        return 1
    fi

    local arr_snapshot_data_streams=()
    # Read the output string into an array. Use mapfile to assign the output to an array:
    mapfile -t arr_snapshot_data_streams <<< "$ret_val"
    log_debug "arr_snapshot_data_streams: ${arr_snapshot_data_streams[*]}"

    if [[ ${#arr_snapshot_data_streams[@]} -eq 0 ]]; then
        log_warning "No data streams found in snapshot: $latest_snapshot"
    else
        for ds in "${arr_snapshot_data_streams[@]}"; do
            fix_backing_indices "$ds" "false"
        done
    fi
}

show_index_ilm_details() {
    local index_name="$1"
    echo >&2
    echo "Index ILM details" >&2
    echo >&2

    # If index name is not provided, prompt user for it
    if [[ -z "$index_name" ]]; then
        read -e -r -p "Enter index name: " index_name
        if [[ -z "$index_name" ]]; then
            echo "Index name is required!"
            return 1
        fi
    fi

    echo "Fetching ILM details for index: $index_name..." >&2
    echo >&2

    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_ilm/explain?pretty"
}

move_index_to_ilm_step() {
    local index_name=""

    echo >&2
    echo "Move index to ILM step" >&2
    echo >&2

    # Prompt user for index name
    read -e -r -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        return 1
    fi

    local current_phase current_action current_step_name

    read -e -r -p "Enter current phase: " current_phase
    if [[ -z "$current_phase" ]]; then
        echo "Current phase is required!"
        return 1
    fi

    read -e -r -p "Enter current action: " current_action
    if [[ -z "$current_action" ]]; then
        echo "Current action is required!"
        return 1
    fi

    read -e -r -p "Enter current step name: " current_step_name
    if [[ -z "$current_step_name" ]]; then
        echo "Current step name is required!"
        return 1
    fi

    local next_phase next_action next_step_name

    read -e -r -p "Enter next phase: " next_phase
    if [[ -z "$next_phase" ]]; then
        echo "Next phase is required!"
        return 1
    fi
    read -e -r -p "Enter next action: " next_action
    if [[ -z "$next_action" ]]; then
        echo "Next action is required!"
        return 1
    fi

    read -e -r -p "Enter next step name: " next_step_name
    if [[ -z "$next_step_name" ]]; then
        echo "Next step name is required!"
        return 1
    fi

    echo "Moving index: $index_name to ILM step (phase): $next_phase..." >&2
    local post_data="{
        \"current_step\": {
            \"phase\": \"$current_phase\",
            \"action\": \"$current_action\",
            \"name\": \"$current_step_name\"
        },
        \"next_step\": {
            \"phase\": \"$next_phase\",
            \"action\": \"$next_action\",
            \"name\": \"$next_step_name\"
        }
    }"

    echo "Post data: " >&2
    echo "$post_data" >&2

    # Ask user if they want to continue
    printf "❓ Do you want to proceed? (y/n): "
    read -e -r confirm

    if [[ "$confirm" != "y" ]]; then
        echo "Moving index to ILM step cancelled."
        return 1
    fi

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/_ilm/move/$index_name?pretty" \
        -H 'Content-Type: application/json' \
        -d "$post_data")

    echo
    echo "$response" | jq .
}

show_ilm_policies() {
    echo && echo "Fetching ILM policies..."

    # Prompt user whether to show names only
    local names_only=""
    read -e -r -p "Show ILM policy names only? (true/false; hit ENTER for false): " names_only
    if [[  -z "$names_only" ]]; then
        names_only="false"
    fi

    # Get the ILM policies in the cluster
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_ilm/policy?pretty" \
        -H "Content-Type: application/json")

    if [[ "$names_only" == "true" ]]; then
        echo "$response" | jq -r 'keys[]'
    else
        echo "$response" | jq .
        echo

        # Use jq to get the Policy name and policy._meta.managed fields, all in one line but padded so that the columns align
        # For some policies, .value.policy._meta.managed field is missing, so we need to handle that case
        echo "$response" | jq -r \
        '
            ["Policy", "Managed", "In use by #indices", "In use by #data streams", "In use by #composable templates"], 
            ["--------", "-------", "--------", "-----------------", "--------------------------"], 
            (
                to_entries[] |
                    [
                        .key,
                        (.value.policy._meta.managed // "N/A"),
                        (.value.in_use_by.indices | length),
                        (.value.in_use_by.data_streams | length),
                        (.value.in_use_by.composable_templates | length)
                    ]
            ) | @tsv
        ' \
        | column -t -s $'\t'
    fi

    # Show managed ILM policies only
    echo
    echo "Managed ILM policies:"
    echo
    echo "$response" | jq -r \
    '
        to_entries[] |
        select(.value.policy._meta.managed == true) |
        .key
    '

    # Show unmanaged ILM policies only
    echo
    echo "Unmanaged ILM policies:"
    echo
    echo "$response" | jq -r \
    '
        to_entries[] |
        select(.value.policy._meta.managed != true) |
        .key
    '
}

show_ilm_policy_details() {
    local policy_name=""
    echo >&2
    echo "Show ILM policy details" >&2
    echo >&2

    # Prompt user for policy name
    read -e -r -p "Enter ILM policy name: " policy_name

    if [[ -z "$policy_name" ]]; then
        echo "ILM policy name is required!"
        return 1
    fi

    echo "Finding ILM policy: $policy_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_ilm/policy/$policy_name?pretty" \
        -H 'Content-Type: application/json')

    echo "$response" | jq .
}

# "/_ilm/policy/metrics-apm.service_transaction_interval_metrics-default_policy.1m?pretty
# {
#   "metrics-apm.service_transaction_interval_metrics-default_policy.1m" : { 
#     "version" : 2,
#     "modified_date" : "2023-05-30T17:53:50.120Z",
#     "policy" : { <-- this value/object is what needs to be in json file
#       "phases" : {
#         ...
#       }
#     },
#     "in_use_by" : {

export_ilm_policy() {
    local policy_name=""
    echo >&2
    echo "Export ILM policy" >&2
    echo >&2

    # Prompt user for policy name
    read -e -r -p "Enter ILM policy name: " policy_name

    if [[ -z "$policy_name" ]]; then
        echo "ILM policy name is required!"
        return 1
    fi

    echo "Exporting ILM policy: $policy_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_ilm/policy/$policy_name?pretty=true" \
        -H 'Content-Type: application/json')

    # echo "$response" | jq -r 'to_entries[] | .value.policy'
    # echo "$response" | jq -r 'to_entries[] | .value.policy' > "$policy_name.json"
    echo "$response" | jq -r '{ policy: .[keys[0]].policy }'
    echo "$response" | jq -r '{ policy: .[keys[0]].policy }' > "$policy_name.json"

    echo "ILM policy $policy_name exported to $policy_name.json"
}

import_ilm_policy() {
    local policy_name=""
    echo >&2
    echo "Import ILM policy" >&2
    echo >&2

    # Prompt user for policy name
    read -e -r -p "Enter ILM policy name: " policy_name

    if [[ -z "$policy_name" ]]; then
        echo "ILM policy name is required!"
        return 1
    fi

    echo "Importing ILM policy: $policy_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X PUT \
        "$ES_HOST/_ilm/policy/$policy_name" \
        -H 'Content-Type: application/json' \
        -d "@$policy_name.json")

    echo "$response" | jq .
}

# We cannot delete policies that are currently in use by indices. If the policy is assigned to any index, the request will fail:
# {
#   "error": {
#     "root_cause": [
#       {
#         "type": "illegal_argument_exception",
#         "reason": "Cannot delete policy [<policy_name>]. It is in use by one or more indices: [...<index_name>, ...]"
#       }
#     ],
#     "type": "illegal_argument_exception",
#     "reason": "Cannot delete policy [<policy_name>]. It is in use by one or more indices: [...<index_name>, ...]"
#   },
#   "status": 400
# }
delete_ilm_policy() {
    local policy_name=""
    echo >&2
    echo "Delete ILM policy" >&2
    echo >&2

    # Prompt user for policy name
    read -e -r -p "Enter ILM policy name: " policy_name

    if [[ -z "$policy_name" ]]; then
        echo "ILM policy name is required!"
        return 1
    fi

    echo "Deleting ILM policy: $policy_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X DELETE \
        "$ES_HOST/_ilm/policy/$policy_name?pretty=true" \
        -H 'Content-Type: application/json')

    echo "$response" | jq .
}

send_get_all_data_streams_request(){
    curl \
            -s \
            -u "$ES_USERNAME:$ES_PASSWORD" \
            -X GET \
            "$ES_HOST/_data_stream/*?expand_wildcards=all&pretty" \
            -H "Content-Type: application/json"
}

# | jq -r '.data_streams[].name'
# '
#     .data_streams[] |
#     .name + "\n" +
#     ( .indices[] | "\t" + .index_name )
# '
show_data_streams() {
    echo && echo "Fetching data streams (and supporting indices)..." >&2

    # Get the data streams in the cluster
    response="$(send_get_all_data_streams_request)"

    echo
    echo "Data streams (names only):"
    echo
    echo "$response" | jq -r '.data_streams[].name'


    echo
    echo "Data streams with supporting indices:"
    echo
    echo "$response" | jq -r \
        '
            .data_streams[] |
            .name + "\n" +
            (.indices | map("\t" + .index_name) | join("\n"))
        '
}

read_lines_to_array() {
    local file_path="$1"
    local -a indices
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        indices+=("$line")
    done < "$file_path"
    
    echo "${indices[@]}"
}

read_items_from_file() {
    # Prompt user to enter the path to the file containing index names
    read -e -r -p "Enter the path to the file: " file_path

    local -a items=()

    if [[ -z "$file_path" ]]; then
        echo "File path is required!" >&2
        return 1
    fi

    # Check if file exists
    if [[ ! -f "$file_path" ]]; then
        echo "File not found: $file_path" >&2
        return 1
    fi

    read_lines_to_array "$file_path"
    return 0
}

close_indices() {
    local index_name=""
    echo >&2
    echo "Close a single or multiple indices" >&2
    echo >&2

    # Prompt user for index name
    read -e -r -p "Enter index name (use wildcard names to match multiple indices; ENTER to load index names from a file): " index_name

    if [[ -z "$index_name" ]]; then

        local exit_code=0
        local output=""
        # check if read_items_from_file returns non-zero code or actual array
        # The || operator executes the right-hand command only if the left-hand command fails (i.e., returns a non-zero exit code)
        output=$(read_items_from_file) || exit_code=$?
        # echo "Exit code: $exit_code"
        local indices=()

        if [[ $exit_code -ne 0 ]]; then
            echo "Error reading indices from file."
            return 1
        fi

        indices=($output)

        # Check if array is empty
        if [[ ${#indices[@]} -eq 0 ]]; then
            echo "No index names found in file: $index_name"
            return 1
        fi

        # Prompt user to confirm closing of indices
        echo
        echo "The following indices will be closed:"
        echo
        
        for index in "${indices[@]}"; do
            echo "$index"
        done

        printf "❓ Do you want to proceed? (y/n): "
        read -e -r confirm

        if [[ "$confirm" != "y" ]]; then
            echo "Closing of indices cancelled."
            return 1
        fi

        # Close indices

        for index in "${indices[@]}"; do
            echo "Closing index: $index..." >&2

            curl \
                -s \
                -u "$ES_USERNAME:$ES_PASSWORD" \
                -X POST \
                "$ES_HOST/$index/_close?pretty=true" \
                -H 'Content-Type: application/json'
        done
    else
        echo "Closing index/indices: $index_name..." >&2

        curl \
            -s \
            -u "$ES_USERNAME:$ES_PASSWORD" \
            -X POST \
            "$ES_HOST/$index_name/_close?pretty=true" \
            -H 'Content-Type: application/json'
    fi
}

# Currently does not work for wildcard indices
# see https://stackoverflow.com/questions/45987172/delete-all-index-with-similary-name

# Reply if "action.destructive_requires_name" in cluster settings is not set to false:
# {
#   "error" : {
#     "root_cause" : [
#       {
#         "type" : "illegal_argument_exception",
#         "reason" : "Wildcard expressions or all indices are not allowed"
#       }
#     ],
#     "type" : "illegal_argument_exception",
#     "reason" : "Wildcard expressions or all indices are not allowed"
#   },
#   "status" : 400
# }
#
# We can
# Deleting index: <index_name>...
# {
#   "error" : {
#     "root_cause" : [
#       {
#         "type" : "illegal_argument_exception",
#         "reason" : "index [<index_name>] is the write index for data stream [<data_stream_name>] and cannot be deleted"
#       }
#     ],
#     "type" : "illegal_argument_exception",
#     "reason" : "index [<index_name>] is the write index for data stream [<data_stream_name>] and cannot be deleted"
#   },
#   "status" : 400
# }
# To overcome this, we can delete the data stream first and then delete the index or we can roll over the data stream to a new index and then delete the old index.
# Rollover API creates a new write index for the data stream and the previous write index becomes a regular backing index that can then be deleted.

# In case of success:
# {
#   "acknowledged" : true
# }
delete_indices() {
    local index_name=""
    echo >&2
    echo "Deletion of a single or multiple indices" >&2
    echo >&2

    # Prompt user for index name
    read -e -r -p "Enter index name (use wildcard names to match multiple indices; ENTER to load index names from a file): " index_name

    if [[ -z "$index_name" ]]; then

        local exit_code=0
        local output=""
        # check if read_items_from_file returns non-zero code or actual array
        # The || operator executes the right-hand command only if the left-hand command fails (i.e., returns a non-zero exit code)
        output=$(read_items_from_file) || exit_code=$?
        # echo "Exit code: $exit_code"
        local indices=()

        if [[ $exit_code -ne 0 ]]; then
            echo "Error reading indices from file."
            return 1
        fi

        indices=($output)

        # Check if array is empty
        if [[ ${#indices[@]} -eq 0 ]]; then
            echo "No index names found in file: $index_name"
            return 1
        fi

        # Prompt user to confirm deletion of indices
        echo
        echo "The following indices will be deleted:"
        echo
        
        for index in "${indices[@]}"; do
            echo "$index"
        done

        printf "❓ Do you want to proceed? (y/n): "
        read -e -r confirm

        if [[ "$confirm" != "y" ]]; then
            echo "Deletion of indices cancelled."
            return 1
        fi

        # Delete indices

        for index in "${indices[@]}"; do
            echo "Deleting index: $index..." >&2

            curl \
                -s \
                -u "$ES_USERNAME:$ES_PASSWORD" \
                -X DELETE \
                "$ES_HOST/$index?pretty=true" \
                -H 'Content-Type: application/json'
        done
    else
        echo "Deleting index/indices: $index_name..." >&2

        curl \
            -s \
            -u "$ES_USERNAME:$ES_PASSWORD" \
            -X DELETE \
            "$ES_HOST/$index_name?pretty=true" \
            -H 'Content-Type: application/json'
    fi
}

copy_data() {
    # Prompt user for source and destination index, alias, or data stream names
    local source=""

    read -e -r -p "Enter source index, alias, or data stream name: " source
    if [[ -z "$source" ]]; then
        echo "Source name is required!"
        return 1
    fi

    local destination=""
    read -e -r -p "Enter destination index, alias, or data stream name: " destination
    if [[ -z "$destination" ]]; then
        echo "Destination name is required!"
        return 1
    fi

    local op_type=""
    echo "If the target is data stream, op_type must be 'create'."
    read -e -r -p "Enter operation type (index/create) or hit ENTER for default (index): " op_type
    if [[ -z "$op_type" ]]; then
        op_type="index"
    fi

    request_body='{
        "source": {
            "index": "'"$source"'"
        },
        "dest": {
            "index": "'"$destination"'",
            "op_type": "'"$op_type"'"
        }
    }'

    echo
    echo "Request body:"
    echo "$request_body"

    echo
    # Ask user if they want to proceed
    printf "❓ Do you want to proceed? (y/n): "
    read -e -r confirm
    if [[ "$confirm" != "y" ]]; then
        echo "Copying data cancelled."
        return 1
    fi

    echo "Copying data from $source to $destination..." >&2
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/_reindex?pretty" \
        -H 'Content-Type: application/json' \
        -d "$request_body")
    echo "$response" | jq .
}

delete_data_stream() {
    local data_stream_name=""
    echo >&2
    echo "Data stream deletion" >&2
    echo >&2

    # Prompt user for data stream name
    read -e -r -p "Enter data stream name: " data_stream_name

    if [[ -z "$data_stream_name" ]]; then
        echo "Data stream name is required!"
        exit 1
    fi

    echo "Deleting data stream: $data_stream_name..." >&2
    echo "This will also delete the backing indices for the data stream." >&2

    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X DELETE \
        "$ES_HOST/_data_stream/$data_stream_name?pretty=true" \
        -H 'Content-Type: application/json'
}

delete_all_data_streams(){
    echo >&2
    echo "Delete all data streams" >&2
    echo >&2

    # Prompt user to confirm deletion of all data streams
    printf "❓ Do you want to proceed? (y/n): "
    read -e -r confirm

    if [[ "$confirm" != "y" ]]; then
        echo "Deletion of all data streams cancelled."
        return 1
    fi

    echo "Deleting all data streams..." >&2

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -u "$ELASTICSEARCH_USERNAME:$ELASTICSEARCH_PASSWORD" \
        -X DELETE \
        "$ELASTICSEARCH_HOST/_data_stream/*")

    # Extract the HTTP status code from the response
    http_code=$(echo "$response" | tail -n1)
    # Extract the JSON response body
    json_response=$(echo "$response" | sed '$d')

    if [ "$http_code" -ne 200 ]; then
        echo "API call failed. HTTP status code: $http_code"
        echo "Response: $json_response"
        exit 1
    fi

    echo "API call successful. HTTP status code: $http_code" >&2
    echo "Response: "
    echo "$json_response" | jq .
}

show_component_templates() {

    # Prompt user whether to show names only
    local names_only=""
    read -e -r -p "Show component template names only? (true/false): " names_only
    
    if [[ -z "$names_only" ]]; then
        echo "Names only value is required!"
        return 1
    fi

    # Echo names_only value
    # echo "Names only: $names_only"

    # Build jq query based on names_only value
    local jq_query=""
    if [[ "$names_only" == "true" ]]; then
        jq_query='.component_templates | to_entries[] | .value.name'
    else
        jq_query='.'
    fi

    echo && echo "Fetching component templates..." >&2
    # Get the component templates in the cluster
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_component_template?pretty" \
        -H "Content-Type: application/json")
    echo "$response" | jq -r "$jq_query" | sort
}

show_component_template() {
    local component_template_name=""
    echo >&2
    echo "Component template details" >&2
    echo >&2

    # Prompt user for component template name
    read -e -r -p "Enter component template name: " component_template_name

    if [[ -z "$component_template_name" ]]; then
        echo "Component template name is required!"
        return 1
    fi

    echo "Finding component template: $component_template_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_component_template/$component_template_name?pretty=true" \
        -H 'Content-Type: application/json')

    echo "$response" | jq .
}


# _component_template/$component_template_name endpoint returns information about a specific component template. JSON response looks like this:
# {
#   "component_templates": [
#     {
#       "name": "metrics-apm.service_destination.1m@package",
#       "component_template": { ... }, <-- this value/object is what needs to be in json file that gets imported
export_component_template(){
    local component_template_name=""
    echo >&2
    echo "Component template export" >&2
    echo >&2

    # Prompt user for component template name
    read -e -r -p "Enter component template name: " component_template_name

    if [[ -z "$component_template_name" ]]; then
        echo "Component template name is required!"
        return 1
    fi

    echo "Exporting component template: $component_template_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_component_template/$component_template_name?pretty=true" \
        -H 'Content-Type: application/json')

    echo "$response" | jq .component_templates[0].component_template
    echo "$response" | jq .component_templates[0].component_template > "$component_template_name.json"

    echo "Component template $component_template_name exported to $component_template_name.json"
}

import_component_template() {
    local component_template_name=""
    local component_template_file=""
    echo >&2
    echo "Component template import" >&2
    echo >&2

    # Prompt user for component template name
    read -e -r -p "Enter component template name: " component_template_name

    if [[ -z "$component_template_name" ]]; then
        echo "Component template name is required!"
        return 1
    fi

    # Prompt user for component template file
    read -e -r -p "Enter component template file: " component_template_file

    if [[ -z "$component_template_file" ]]; then
        echo "Component template file is required!"
        return 1
    fi

    echo "Importing component template: $component_template_name from file: $component_template_file..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X PUT \
        "$ES_HOST/_component_template/$component_template_name?pretty=true" \
        -H 'Content-Type: application/json' \
        -d "@$component_template_file")

    echo "$response" | jq .
    echo "Component template imported: $component_template_name"
}

show_index_templates() {

    # Prompt user whether to show names only
    local names_only=""
    read -e -r -p "Show index template names only? (true/false): " names_only
    
    if [[ -z "$names_only" ]]; then
        echo "Names only value is required!"
        return 1
    fi

    # Echo names_only value
    # echo "Names only: $names_only"

    local used_component_templates=false

    if [[ "$names_only" == "true" ]]; then
        # Prompt user whether to show used component templates
        
        read -e -r -p "Show used component templates? (true/false): " used_component_templates

        if [[ -z "$used_component_templates" ]]; then
            echo "Used component templates value is required!"
            return 1
        fi

        # Echo used_component_templates value
        # echo "Used component templates: $used_component_templates"
    else
        echo "Names only: $names_only"
    fi

    echo && echo "Fetching index templates count..." >&2

    # Get the number of index templates in the cluster
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template?pretty" \
        -H "Content-Type: application/json")
    echo "Index templates count:" $(echo "$response" | jq -r '.index_templates | length')

    # Get the index templates in the cluster
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template?pretty" \
        -H "Content-Type: application/json")

    echo && echo "Fetching index templates..." >&2
    
    # Echo response depending on names_only and used_component_templates values
    if [[ "$names_only" == "true" ]]; then
        if [[ "$used_component_templates" == "true" ]]; then
            # echo "$response" | jq -r '.index_templates | to_entries[] | sort_by(.value.name) | .value.name + "\n" + (.value.index_template.composed_of[] | map("\t" + .) | join("\n") | .[])'
            echo "$response" | jq -r '.index_templates | sort_by(.name) | .[] | .name, "\tComponent template(s):", (.index_template.composed_of | map("\t\t" + .) | .[]), "\tIndex patterns:", (.index_template.index_patterns | map("\t\t" + .) | .[]), "\n"'
        else
            echo "$response" | jq -r '.index_templates | to_entries[] | .value.name' | sort
        fi
    else
        echo "$response" | jq .
    fi
}

show_index_template() {
    local index_template_name=""
    echo >&2
    echo "Index template details" >&2
    echo >&2

    # Prompt user for index template name
    read -e -r -p "Enter index template name: " index_template_name

    if [[ -z "$index_template_name" ]]; then
        echo "Index template name is required!"
        return 1
    fi

    echo "Fetching index template: $index_template_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template/$index_template_name?pretty=true" \
        -H 'Content-Type: application/json')
    echo "$response" | jq .

    # Extract index template patterns
    local index_patterns=$(echo "$response" | jq -r '.index_templates[0].index_template.index_patterns[]')

    if [[ -z "$index_patterns" ]]; then
        echo "Template '$index_template_name' not found or has no patterns."
    else
        echo
        echo "Index patterns:"
        echo
        echo "$index_patterns"

        # Fetch and show all indices that use this index template
        echo
        echo "Indices using this index template:"
        echo
        # Iterate through each pattern and find matching indices
        for pattern in $index_patterns; do
            curl \
                -s \
                -u "$ES_USERNAME:$ES_PASSWORD" \
                -X GET \
                "$ES_HOST/_cat/indices/$pattern?h=index" \
                | while read -r index; do
                    echo "$index"
                done
        done
    fi
}

# _index_template/$index_template_name endpoint returns information about a specific index template. JSON response looks like this:
# {
#   "index_templates": [
#     {
#       "name": "metrics-apm.service_destination.1m",
#       "index_template": { ... }, <-- this value/object is what needs to be in json file that gets imported
export_index_template() {
    local index_template_name=""
    echo >&2
    echo "Index template export" >&2
    echo >&2

    # Prompt user for index template name
    read -e -r -p "Enter index template name: " index_template_name

    if [[ -z "$index_template_name" ]]; then
        echo "Index template name is required!"
        return 1
    fi

    echo "Exporting index template: $index_template_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template/$index_template_name?pretty=true" \
        -H 'Content-Type: application/json')

    echo "$response" | jq .index_templates[0].index_template
    echo "$response" | jq .index_templates[0].index_template > "$index_template_name.json"

    echo "Index template exported to $index_template_name.json"
}

# If index template being imported contains some component templates which don't exist in the cluster, the import will fail:
# {
#   "error": {
#     "root_cause": [
#       {
#         "type": "invalid_index_template_exception",
#         "reason": "index_template [metrics-apm.service_destination.1m] invalid, cause [index template [metrics-apm.service_destination.1m] specifies component templates [metrics-apm.service_destination.1m@package] that do not exist]"
#       }
#     ],
#     "type": "invalid_index_template_exception",
#     "reason": "index_template [metrics-apm.service_destination.1m] invalid, cause [index template [metrics-apm.service_destination.1m] specifies component templates [metrics-apm.service_destination.1m@package] that do not exist]"
#   },
#   "status": 400
# }
import_index_template(){
    local index_template_name=""
    local index_template_file=""
    echo >&2
    echo "Index template import" >&2
    echo >&2

    # Prompt user for index template name
    read -e -r -p "Enter index template name: " index_template_name

    if [[ -z "$index_template_name" ]]; then
        echo "Index template name is required!"
        return 1
    fi

    # Prompt user for index template file
    read -e -r -p "Enter index template file: " index_template_file

    if [[ -z "$index_template_file" ]]; then
        echo "Index template file is required!"
        return 1
    fi

    echo "Importing index template: $index_template_name from file: $index_template_file..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X PUT \
        "$ES_HOST/_index_template/$index_template_name?pretty=true" \
        -H 'Content-Type: application/json' \
        --data-binary "@$index_template_file")
    echo "$response" | jq .

    echo "Index template $index_template_name imported from $index_template_file"
}

# In case of success, the response will be:
# {
#   "acknowledged": true
# }
delete_index_template() {
    local index_template_name=""
    echo >&2
    echo "Index template deletion" >&2
    echo >&2

    # Prompt user for index template name
    read -e -r -p "Enter index template name (use wildcard names to match multiple index templates): " index_template_name

    if [[ -z "$index_template_name" ]]; then
        echo "Index template name is required!"
        exit 1
    fi

    echo "Deleting index template: $index_template_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X DELETE \
        "$ES_HOST/_index_template/$index_template_name?pretty=true" \
        -H 'Content-Type: application/json')
    echo "$response" | jq .
}

delete_component_template() {
    local component_template_name=""
    echo >&2
    echo "Component template deletion" >&2
    echo >&2

    # Prompt user for component template name
    read -e -r -p "Enter component template name: " component_template_name

    if [[ -z "$component_template_name" ]]; then
        echo "Component template name is required!"
        exit 1
    fi

    echo "Deleting component template: $component_template_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X DELETE \
        "$ES_HOST/_component_template/$component_template_name?pretty=true" \
        -H 'Content-Type: application/json')
    echo "$response" | jq .
}

show_aliases() {
    echo
    echo "Fetching aliases (_alias endpoint)..." >&2
    echo

    # This will list all aliases in the cluster and their associated indices. 
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_alias?pretty" \
        -H "Content-Type: application/json")
    echo "$response" | jq --sort-keys .


    echo
    echo "Fetching aliases (_aliases endpoint)..." >&2
    echo
    echo "List of indices with aliases:"

    # Get the aliases in the cluster
    # By default, _aliases does not return aliases for hidden indices (indices starting with .).
    # To include hidden indices in the response, use expand_wildcards=all to include hidden indices
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_aliases?expand_wildcards=all&pretty" \
        -H "Content-Type: application/json")
    echo "$response" | jq --sort-keys .

    # echo
    # echo "Number of indices with 'aliases' field present:"
    # echo "$response" | jq -r '. | to_entries | length'

    # echo
    # echo "Number of indices with aliases:"
    # echo "$response" | jq -r '. | to_entries | map(select(.value.aliases | length > 0)) | length'

    # Print only index names with aliases, in a table format
    echo
    echo "List of index names with aliases:"
    echo "(Note that the same index can have multiple aliases and hence can be listed multiple times)"
    # 
    # echo "(Also note that hidden indices are not included in the response)"
    echo
    echo "$response" | jq -r \
    '
        ["Index", "Alias"], 
        ["--------", "-------"], 
        (to_entries | sort_by(.key)[] | select(.value.aliases | length > 0) | 
        .key as $index | .value.aliases | keys[] | [$index, .]) | @tsv
    ' \
    | column -t -s $'\t'

    # select(.value.aliases | length > 0) |[.key, (.value.aliases | keys)] | @tsv
    #
    # _alias endpoint returns the same information as _aliases endpoint so can be commented out
    #
    # echo
    # echo "List of aliases (_alias endpoint):"
    # echo

    # response=$(curl \
    #     -s \
    #     -u "$ES_USERNAME:$ES_PASSWORD" \
    #     -X GET \
    #     "$ES_HOST/.*,*/_alias?pretty&expand_wildcards=all" \
    #     -H "Content-Type: application/json")
    # echo "$response" | jq --sort-keys .

    # echo
    # echo "Number of aliases:"
    # echo "$response" | jq -r '. | to_entries | length'

    echo
    echo "List of aliases (CAT API):"
    echo
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/aliases?v=true&expand_wildcards=all&h=index,alias&s=index"
    )
    echo "$response"

    echo
    echo "Number of aliases:"
    echo "$response" | wc -l | awk '{print $1 - 1}'
}

find_alias() {
    local alias_name=""
    echo >&2
    echo "Find alias" >&2
    echo >&2

    # Prompt user for alias name
    read -e -r -p "Enter alias name: " alias_name

    if [[ -z "$alias_name" ]]; then
        echo "Alias name is required!"
        return 1
    fi

    echo "Finding alias: $alias_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_alias/$alias_name?pretty=true" \
        -H 'Content-Type: application/json')
    echo "$response" | jq .
}

create_alias(){
    local alias_name=""
    local index_name=""
    echo >&2
    echo "Create alias" >&2
    echo >&2

    # Prompt user for alias name
    read -e -r -p "Enter alias name: " alias_name

    if [[ -z "$alias_name" ]]; then
        echo "Alias name is required!"
        return 1
    fi

    # Prompt user for index name
    read -e -r -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        return 1
    fi

    echo "Creating alias: $alias_name for index: $index_name..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X PUT \
        "$ES_HOST/_alias/$alias_name/$index_name?pretty=true" \
        -H 'Content-Type: application/json')
    echo "$response" | jq .
}

add_alias_to_index(){
    local index_name=""
    local alias_input=""
    echo >&2
    echo "Add alias to index" >&2
    echo >&2

    # Prompt user for index name
    read -e -r -p "Enter the index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        return 1
    fi

    # Prompt user for alias name
    read -e -r -p "Enter the alias name: " alias_input

    if [[ -z "$alias_input" ]]; then
        echo "Alias name is required!"
        return 1
    fi

    # Prompt user for is_write_index
    # While an alias can point to multiple indices for read operations, only one index
    # can be designated as the write index for an alias. This is specified using the
    # "is_write_index" parameter when setting up the alias.

    local is_write_index=""
    read -e -r -p "Is this a write index? (true/false; hit ENTER for false): " is_write_index

    if [[ -z "$is_write_index" ]]; then
        is_write_index="false"
    fi

    echo "Adding alias $alias_input to index: $index_name..." >&2

    local request_body='{
        "actions": [
            {
                "add": {
                    "index": "'$index_name'",
                    "alias": "'$alias_input'",
                    "is_write_index": '$is_write_index'
                }
            }
        ]
    }'

    echo
    echo "Request body:"
    echo "$request_body" | jq .

    # Prompt user whether to go ahead with the operation
    local proceed=""
    read -e -r -p "Proceed with adding alias to index? (y/n): " proceed

    if [[ "$proceed" != "y" ]]; then
        echo "Operation aborted!"
        return 1
    fi

    curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X POST \
        "$ES_HOST/_aliases" \
        -H 'Content-Type: application/json' \
        -d "$request_body"
}

list_agents() {
    echo && echo "Fetching Fleet agents..."
    # Get the agents in the cluster
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/.fleet-agents/_search?pretty" \
        -H "Content-Type: application/json" \
        -d \
        '{
            "query": {
                "match_all": {}
            },
            "_source": ["agent_id"],
            "size": 10000
        }')

    echo && echo "Fleet agents count:"
    echo "$response" | jq -r '.hits.total.value'

    echo && echo "Fleet agents id:"
    echo "$response" | jq -r '.hits.hits[] | ._id'
}

# The same as list_agents, but with using a different endpoint
# Use ?kuery=status:offline to get offline agents
list_agents_kibana_endpoint() {
    echo && echo "Fetching Fleet agents (using Kibana API)..."

    # Prompt user whether to show verbose output
    local verbose_output="false"
    read -e -r -p "Show verbose output? (true/false; hit ENTER for default value - false): " verbose_output

    if [[ -z "$verbose_output" ]]; then
        verbose_output="false"
    fi

    echo "Verbose output: $verbose_output"

    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X GET \
        "$KIBANA_HOST_ORIGIN/api/fleet/agents?perPage=100" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true')

    if [[ "$verbose_output" == "true" ]]; then
        echo "$response" | jq .
    else
         echo "$response" | jq -r '.list[] | .id + " " + .status'
    fi
}

get_agent_ids() {
    echo && echo "Fetching Fleet agent IDs (using Kibana API)..." >&2

    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X GET \
        "$KIBANA_HOST_ORIGIN/api/fleet/agents?perPage=100" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true')

    local agent_ids_array=($(echo "$response" | jq -r '.list[] | .id'))
    echo "${agent_ids_array[@]}"
}

# The bulk_unenroll operation is a Fleet-specific function, and Fleet is managed
# through Kibana's interface. While Elasticsearch is used for storing agent data,
# the management operations for Fleet are handled by Kibana's API
unenroll_agents() {
    echo && echo "Unenrolling Fleet agents (using Kibana API)..."

    local fleet_agent_ids_array=($(get_agent_ids))
    echo "fleet_agent_ids_array: ${fleet_agent_ids_array[@]}"

    if [ ${#fleet_agent_ids_array[@]} -eq 0 ]; then
        echo "No Fleet agents found!"
        return 1
    fi

    echo && echo "Fleet agent IDs: "
    for agent_id in "${fleet_agent_ids_array[@]}"; do
        echo "$agent_id"
    done

    # Convert array to JSON array
    local agent_ids_json_array=$(printf '%s\n' "${fleet_agent_ids_array[@]}" | jq -R . | jq -s .)
    echo "agent_ids_json_array = $agent_ids_json_array"

    # Test for dry run. Comment out the following line to actually unenroll agents:
    agent_ids_json_array="[]"
    echo "agent_ids_json_array = $agent_ids_json_array"

    echo "Sendind POST request to unenroll agents..."

    # Output can look like this:
    # {"actionId":"b97c1e24-2d97-4b47-910d-290fa1a13425"}
    curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X POST \
        "$KIBANA_HOST_ORIGIN/api/fleet/agents/bulk_unenroll" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true' \
        -d \
        "{
            \"agents\": $agent_ids_json_array,
            \"force\": true,
            \"revoke\": true
        }"
}

# The Fleet server is a special agent that is responsible for managing other agents.
# This command will retrieve a list of all fleet server hosts configured in your Elastic environment.
# The response will include details about each fleet server host, such as its ID, host URL, and whether it's a default host.
show_fleet_server_hosts() {
    echo && echo "Fetching Fleet server hosts (using Kibana API)..."

    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X GET \
        "$KIBANA_HOST_ORIGIN/api/fleet/fleet_server_hosts" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true')

    echo "$response" | jq .
}

delete_fleet_server_host() {
    echo && echo "Deleting Fleet server host (using Kibana API)..."

    local fleet_server_host_id=""
    echo
    echo "Fleet server host deletion"
    echo

    # Prompt user for fleet server host ID
    read -e -r -p "Enter Fleet server host ID: " fleet_server_host_id

    if [[ -z "$fleet_server_host_id" ]]; then
        echo "Fleet server host ID is required!"
        return 1
    fi

    echo "Deleting Fleet server host: $fleet_server_host_id..." >&2

    curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X DELETE \
        "$KIBANA_HOST_ORIGIN/api/fleet/fleet_server_hosts/$fleet_server_host_id" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true'
}

update_fleet_server_host() {
    echo && echo "Updating Fleet server host (using Kibana API)..."

    local fleet_server_host_id=""
    echo
    echo "Fleet server host update"
    echo

    # Prompt user for fleet server host ID
    read -e -r -p "Enter Fleet server host ID: " fleet_server_host_id

    if [[ -z "$fleet_server_host_id" ]]; then
        echo "Fleet server host ID is required!"
        return 1
    fi

    echo "Updating Fleet server host: $fleet_server_host_id..." >&2

    # Prompt user for host URLs (strings separated by space)
    read -e -r -p "Enter Fleet server host URL: " fleet_server_host
    
    # Validate the input
    if [[ -z "$fleet_server_host" ]]; then
        echo "Fleet server host URL is required!"
        return 1
    fi

    # Turn input into bash array
    IFS=' ' read -r -a fleet_server_host_array <<< "$fleet_server_host"

    # Print the fleet_server_host_array
    echo "Fleet server host URLs: ${fleet_server_host_array[@]}"

    # Convert bash array to json array
    fleet_server_host_json_array=$(printf '%s\n' "${fleet_server_host_array[@]}" | jq -R . | jq -s .)

    # Print the fleet_server_host_json_array
    echo "Fleet server host URLs (JSON): $fleet_server_host_json_array"

    # Prompt user for default host
    read -e -r -p "Is this the default Fleet server host? (true/false): " default_host

    if [[ -z "$default_host" ]]; then
        echo "Default host value is required!"
        return 1
    fi

    # Print default host value
    echo "Default host: $default_host"

    # Test for dry run. Comment out the following line to actually update the fleet server host:
    # fleet_server_host_id=""

    request_body='{
        "host_urls": '"$fleet_server_host_json_array"',
        "is_default": '"$default_host"'
    }'

    # Print request body
    echo "Request body: $request_body"

    echo "Sending PUT request to update Fleet server host..."

    # Output can look like this:
    # {
    #   "item": {
    #       "id":"cd9b14fd-78ab-4053-8120-d5cb0d0ac7e7",
    #       "host_urls":["https://eck-fleet-server.mycorp-test.com:443"],
    #       "is_default":false,
    #       "name":"fleet",
    #       "is_preconfigured":false,
    #       "proxy_id":null
    #   }
    # }
    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X PUT \
        "$KIBANA_HOST_ORIGIN/api/fleet/fleet_server_hosts/$fleet_server_host_id" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true' \
        -d \
        "$request_body")

    echo "$response" | jq .
}

show_fleet_outputs() {
    echo && echo "Fetching Fleet outputs (using Kibana API)..."

    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X GET \
        "$KIBANA_HOST_ORIGIN/api/fleet/outputs" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true')

    echo "$response" | jq .
}

update_fleet_output() {
    echo && echo "Updating Fleet output (using Kibana API)..."

    local fleet_output_id=""
    echo
    echo "Fleet output update"
    echo

    # Prompt user for fleet output ID
    read -e -r -p "Enter Fleet output ID: " fleet_output_id

    if [[ -z "$fleet_output_id" ]]; then
        echo "Fleet output ID is required!"
        return 1
    fi

    echo "Updating Fleet output: $fleet_output_id..." >&2

    # Prompt user for is_default
    read -e -r -p "Is this the default Fleet output? (true/false): " is_default

    if [[ -z "$is_default" ]]; then
        echo "is_default value is required!"
        return 1
    fi

    # Print is_default value
    echo "is_default: $is_default"

    # Prompt user for is_default_monitoring
    read -e -r -p "Is this the default monitoring output? (true/false): " is_default_monitoring

    if [[ -z "$is_default_monitoring" ]]; then
        echo "is_default_monitoring value is required!"
        return 1
    fi

    # Print is_default_monitoring value
    echo "is_default_monitoring: $is_default_monitoring"

    # Prompt user for output type
    # read -p "Enter Fleet output type (elasticsearch, syslog, etc.): " output_type

    # Validate the input
    # if [[ -z "$output_type" ]]; then
    #     echo "Fleet output type is required!"
    #     return 1
    # fi

    # Print the output type
    # echo "Fleet output type: $output_type"

    # Prompt user for output hosts (strings separated by space)
    # read -p "Enter Fleet output hosts: " output_hosts

    # Validate the input
    # if [[ -z "$output_hosts" ]]; then
    #     echo "Fleet output hosts are required!"
    #     return 1
    # fi

    # Turn input into bash array
    # IFS=' ' read -r -a output_hosts_array <<< "$output_hosts"

    # Print the output_hosts_array
    # echo "Fleet output hosts: ${output_hosts_array[@]}"

    # Convert bash array to json array
    # output_hosts_json_array=$(printf '%s\n' "${output_hosts_array[@]}" | jq -R . | jq -s .)

    # Print the output_hosts_json_array
    # echo "Fleet output hosts (JSON): $output_hosts_json_array"

    # Prompt user for output API key
    # read -p "Enter Fleet output API key: " output_api_key

    # Validate the input
    # if [[ -z "$output_api_key" ]]; then
    #     echo "Fleet output API key is required!"
    #     return 1
    # fi

    # Print the output API key
    # echo "Fleet output API key: $output_api_key"

    # Test for dry run. Comment out the following line to actually update the fleet output:
    # fleet_output_id=""

    request_body='{
        "is_default": '"$is_default"',
        "is_default_monitoring": '"$is_default_monitoring"'
    }'

    # Print request body
    echo "Request body: $request_body"

    echo "Sending PUT request to update Fleet output..."

    # Output can look like this:
    # {
    #   "statusCode": 400,
    #   "error": "Bad Request",
    #   "message": "Default output af8c3f1b-b7fa-4765-9e34-bf8cbba3acee cannot be set to is_default=false or is_default_monitoring=false manually. Make another output the default first."
    # }
    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X PUT \
        "$KIBANA_HOST_ORIGIN/api/fleet/outputs/$fleet_output_id" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true' \
        -d \
        "$request_body")
    
    echo "$response" | jq .
}

#
# Ingest
#

show_pipelines() {
    echo && echo "Fetching ingest pipelines..."

    # Prompt user whether to show verbose output
    local verbose="false"
    read -e -r -p "Show verbose output? (true/false; hit ENTER for false): " verbose

    if [[ -z "$verbose" ]]; then
        verbose="false"
    fi

    echo "Verbose: $verbose"
    echo

    # Get the ingest pipelines in the cluster
    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_ingest/pipeline?pretty" \
        -H "Content-Type: application/json")

    if [[ "$verbose" == "true" ]]; then
        echo "$response" | jq .
    else
        # Use jq to get the pipeline name, _meta.managed and _meta.managed_by fields, all in one line but padded so that the columns align
        echo "$response" | jq -r \
        '
            ["Pipeline", "Managed", "Managed By"], 
            ["--------", "-------", "----------"], 
            (to_entries | sort_by(.key)[] |
            [.key, .value._meta.managed, .value._meta.managed_by]) | @tsv
        ' \
        | column -t -s $'\t'
    fi

    # Print the number of ingest pipelines
    echo
    echo "Number of ingest pipelines: $(echo "$response" | jq -r 'keys | length')"
}

show_pipeline_details() {
    local pipeline_id=""
    echo >&2
    echo "Ingest pipeline details" >&2
    echo >&2

    # Prompt user for pipeline ID
    read -e -r -p "Enter pipeline ID: " pipeline_id

    if [[ -z "$pipeline_id" ]]; then
        echo "Pipeline ID is required!"
        exit 1
    fi

    echo "Fetching details for pipeline: $pipeline_id..." >&2

    response=$(curl \
        -s \
        -u "$ES_USERNAME:$ES_PASSWORD" \
        -X GET \
        "$ES_HOST/_ingest/pipeline/$pipeline_id?pretty" \
        -H "Content-Type: application/json")
    echo "$response" | jq .
}

show_processors() {
    log_warning "\nNot implemented yet..."

    # echo && echo "Fetching ingest processors..."
    # # Get the ingest processors in the cluster
    # response=$(curl \
    #     -s \
    #     -u "$ES_USERNAME:$ES_PASSWORD" \
    #     -X GET \
    #     "$ES_HOST/_ingest/processor/attachment?pretty" \
    #     -H "Content-Type: application/json")
    # echo "$response" | jq .
}

show_kibana_settings() {
    log_empty_line
    log_wait "Fetching Kibana settings..."

    # Get the Kibana settings in the cluster
    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X GET \
        "$KIBANA_HOST_ORIGIN/api/kibana/settings" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true')
    log_string "$(echo "$response" | jq .)"
}

show_menu_select_message() {
    local menu_name=$1
    local env=$ENV

    if [[ "$ENV" == "prod" ]]; then
        env="!!! $ENV !!!"
    fi

    echo >&2
    log_prompt "($env) [$menu_name] Please select an option:"
}

main_menu() {
    local menu_options=(
        "cluster"
        "snapshots"
        "indices"
        "fleet"
        "ingest"
        "kibana"
        "EXIT"
    )

    while true; do
        show_menu_select_message "main menu"

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "cluster")
                        cluster_menu
                        ;;
                    "snapshots")
                        snapshots_menu
                        ;;
                    "indices")
                        indices_menu
                        ;;
                    "fleet")
                        fleet_menu
                        ;;
                    "ingest")
                        ingest_menu
                        ;;
                    "kibana")
                        kibana_menu
                        ;;
                    "EXIT")
                        log_finish "Exiting..."
                        exit 0
                        ;;
                    *)
                        log_error "Invalid option"
                        ;;
                esac
                break
            else
                log_error "Invalid selection. Please choose a valid option."
            fi
        done
    done
}

cluster_menu() {
    local menu_options=(
        "health"
        "state (verbose)"
        "show settings"
        "edit settings"
        "nodes info"
        "nodes info (verbose)"
        "nodes settings (verbose)"
        "show kibana settings"
        "EXIT"
    )

    while true; do
        show_menu_select_message "cluster"

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "health")
                        check_cluster_health
                        ;;
                    "state (verbose)")
                        show_cluster_state
                        ;;
                    "show settings")
                        show_cluster_settings
                        ;;
                    "edit settings")
                        edit_cluster_settings
                        ;;
                    "nodes info")
                        show_nodes_info
                        ;;
                    "nodes info (verbose)")
                        show_nodes_info_verbose
                        ;;
                    "nodes settings (verbose)")
                        show_nodes_settings
                        ;;
                    "show kibana settings")
                        show_kibana_settings
                        ;;
                    "EXIT")
                        # log_finish "Exiting the submenu..."
                        return 0
                        ;;
                    *)
                        log_error "Invalid option"
                        ;;
                esac
                break
            else
                log_error "Invalid selection. Please choose a valid option."
            fi
        done
    done
}

COLUMNS=1 # Set the number of columns for the select menu
indices_menu() {
    local menu_options=(
        "show indices"
        "show index/indices details"
        "show indices with ILM errors"
        "show indices with ILM errors (verbose)"
        "show index ILM details"
        "move index to ILM step"
        "show documents in index"
        "show documents count"
        "modify setting for indices"
        "close index"
        "close indices"
        "delete indices"
        "copy data (reindex)"
        "show data streams"
        "show data stream"
        "create data stream"
        "show documents in data stream"
        "rollover data stream"
        "add index to data stream"
        "remove index from data stream"
        "fix backing indices"
        "fix backing indices (multiple streams)"
        "fix backing indices (snapshot streams)"
        "fix backing index rollover info"
        "delete data stream"
        "delete all data streams"
        "show index templates"
        "show index template"
        "export index template"
        "import index template"
        "delete index template"
        "show component templates"
        "show component template"
        "export component template"
        "import component template"
        "delete component template"
        "show ILM policies"
        "show ILM policy details"
        "export ILM policy"
        "import ILM policy"
        "delete ILM policy"
        "show mapping for index"
        "show all mappings in cluster"
        "show aliases"
        "find alias"
        "create alias"
        "add alias to index"
        "shards status"
        "EXIT"
    )

    while true; do
        show_menu_select_message "indices"

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "show indices")
                        show_indices
                        ;;
                    "show index/indices details")
                        show_index_details
                        ;;
                    "show indices with ILM errors")
                        show_indices_with_ilm_errors
                        ;;
                    "show indices with ILM errors (verbose)")
                        show_indices_with_ilm_errors_detailed
                        ;;
                    "show index ILM details")
                        show_index_ilm_details
                        ;;
                    "move index to ILM step")
                        move_index_to_ilm_step
                        ;;
                    "show documents in index")
                        show_documents_in_index
                        ;;
                    "show documents count")
                        show_documents_count
                        ;;
                    "modify setting for indices")
                        modify_setting_for_indices
                        ;;
                    "close index")
                        close_index
                        ;;
                    "close indices")
                        close_indices
                        ;;
                    "delete indices")
                        delete_indices
                        ;;
                    "copy data (reindex)")
                        copy_data
                        ;;
                    "show data streams")
                        show_data_streams
                        ;;
                    "show data stream")
                        show_data_stream
                        ;;
                    "create data stream")
                        create_data_stream
                        ;;
                    "show documents in data stream")
                        show_documents_in_data_stream
                        ;;
                    "rollover data stream")
                        rollover_data_stream
                        ;;
                    "add index to data stream")
                        add_index_to_data_stream
                        ;;
                    "remove index from data stream")
                        remove_index_from_data_stream
                        ;;
                    "fix backing indices")
                        fix_backing_indices
                        ;;
                    "fix backing indices (multiple streams)")
                        fix_backing_indices_multiple_streams
                        ;;
                    "fix backing indices (snapshot streams)")
                        fix_backing_indices_snapshot_streams
                        ;;
                    "fix backing index rollover info")
                        fix_backing_index_rollover_info
                        ;;
                    "delete data stream")
                        delete_data_stream
                        ;;
                    "delete all data streams")
                        delete_all_data_streams
                        ;;
                    "show index templates")
                        show_index_templates
                        ;;
                    "show index template")
                        show_index_template
                        ;;
                    "export index template")
                        export_index_template
                        ;;
                    "import index template")
                        import_index_template
                        ;;
                    "delete index template")
                        delete_index_template
                        ;;
                    "show component templates")
                        show_component_templates
                        ;;
                    "show component template")
                        show_component_template
                        ;;
                    "export component template")
                        export_component_template
                        ;;
                    "import component template")
                        import_component_template
                        ;;
                    "delete component template")
                        delete_component_template
                        ;;
                    "show ILM policies")
                        show_ilm_policies
                        ;;
                    "show ILM policy details")
                        show_ilm_policy_details
                        ;;
                    "export ILM policy")
                        export_ilm_policy
                        ;;
                    "import ILM policy")
                        import_ilm_policy
                        ;;
                    "delete ILM policy")
                        delete_ilm_policy
                        ;;
                    "show mapping for index")
                        show_mapping_for_index
                        ;;
                    "show all mappings in cluster")
                        show_all_mappings_in_cluster
                        ;;
                    "show aliases")
                        show_aliases
                        ;;
                    "find alias")
                        find_alias
                        ;;
                    "create alias")
                        create_alias
                        ;;
                    "shards status")
                        shards_status_report
                        ;;
                    "add alias to index")
                        add_alias_to_index
                        ;;
                    "EXIT")
                        # log_finish "Exiting the submenu..."
                        return 0
                        ;;
                    *)
                        log_error "Invalid option"
                        ;;
                esac
                break
            else
                log_error "Invalid selection. Please choose a valid option."
            fi
        done
    done
}

snapshots_menu() {
    local menu_options=(
        "list snapshot repositories"
        "verify snapshot repositories"
        "show SLM policies"
        "show details of the latest snapshot"
        "restore snapshot"
        "EXIT"
    )

    while true; do
        show_menu_select_message "snapshots"

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "list snapshot repositories")
                        list_snapshot_repositories
                        ;;
                    "verify snapshot repositories")
                        verify_snapshot_repositories
                        ;;
                    "show SLM policies")
                        show_slm_policies_details
                        ;;
                    "show details of the latest snapshot")
                        show_latest_snapshot_details
                        ;;
                    "restore snapshot")
                        restore_snapshot
                        ;;
                    "EXIT")
                        # log_finish "Exiting the submenu..."
                        return 0
                        ;;
                    *)
                        log_error "Invalid option"
                        ;;
                esac
                break
            else
                log_error "Invalid selection. Please choose a valid option."
            fi
        done
    done
}

fleet_menu() {
    local menu_options=(
        "list agents"
        "unenroll agents"
        "show fleet server hosts"
        "update fleet server host"
        "delete fleet server host"
        "show fleet outputs"
        "update fleet output"
        "EXIT"
    )

    while true; do
        show_menu_select_message "fleet"

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "list agents")
                        list_agents
                        list_agents_kibana_endpoint
                        ;;
                    "unenroll agents")
                        unenroll_agents
                        ;;
                    "show fleet server hosts")
                        show_fleet_server_hosts
                        ;;
                    "update fleet server host")
                        update_fleet_server_host
                        ;;
                    "delete fleet server host")
                        delete_fleet_server_host
                        ;;
                    "show fleet outputs")
                        show_fleet_outputs
                        ;;
                    "update fleet output")
                        update_fleet_output
                        ;;
                    "EXIT")
                        # log_finish "Exiting the submenu..."
                        return 0
                        ;;
                    *)
                        log_error "Invalid option"
                        ;;
                esac
                break
            else
                log_error "Invalid selection. Please choose a valid option."
            fi
        done
    done
}

ingest_menu() {
    local menu_options=(
        "show pipelines"
        "show pipeline details"
        "show processors"
        "EXIT"
    )

    while true; do
        show_menu_select_message "ingest"

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "show pipelines")
                        show_pipelines
                        ;;
                    "show pipeline details")
                        show_pipeline_details
                        ;;
                    "show processors")
                        show_processors
                        ;;
                    "EXIT")
                        # log_finish "Exiting the submenu..."
                        return 0
                        ;;
                    *)
                        log_error "Invalid option"
                        ;;
                esac
                break
            else
                log_error "Invalid selection. Please choose a valid option."
            fi
        done
    done
}

show_all_spaces() {
    log_trace "show_all_spaces()"

    local response
    local http_code
    local payload

    log_wait "Fetching all spaces..."

    local path="/api/spaces/space"

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X GET \
        -H "kbn-xsrf: true" \
        -u "$KIBANA_USERNAME":"$KIBANA_PASSWORD" \
        "$KIBANA_HOST_ORIGIN$path"
    )

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Unable to fetch all spaces. HTTP status code: $http_code"
        log_error "Response: $response"
        exit 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')

    if [[ -z "$payload" ]]; then
        log_error "Empty payload in response from the server."
        exit 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Invalid JSON response."
        log_error "Response: $payload"
        exit 1
    fi

    # printf "%s" "$payload"
    log_success "$path output:\n$(echo "$payload" | jq .)"
    log_empty_line

    log_info "List of space names:\n$(echo "$payload" | jq -r '.[].id')"
}

show_current_space() {
    log_trace "show_current_space()"

    local response
    local http_code
    local payload

    log_wait "Fetching current space..."

    local path="/api/spaces/space"

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X GET \
        -H "kbn-xsrf: true" \
        -u "$KIBANA_USERNAME":"$KIBANA_PASSWORD" \
        "$KIBANA_HOST_ORIGIN$path"
    )

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Unable to fetch current space. HTTP status code: $http_code"
        log_error "Response: $response"
        exit 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')

    if [[ -z "$payload" ]]; then
        log_error "Empty payload in response from the server."
        exit 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Invalid JSON response."
        log_error "Response: $payload"
        exit 1
    fi

    # printf "%s" "$payload"
    log_success "$path output:\n$(echo "$payload" | jq .)"
    log_empty_line
}

# Fetch the list of allowed types.
# This is required to get the list of saved object types that can be exported.
#
# The list of allowed types is different for different Kibana versions and configurations.
# It is not exhaustive and may not include all types. For example, the list may not include
# specialized types like connector, log-view, rule, ml-module, ml-job and timelion-sheet types.
#
# index-pattern is an alias for data-view (Index Patterns are now called Data Views).
#
# Expected output of /api/kibana/management/saved_objects/_allowed_types is JSON.
get_allowed_types_response_payload() {
    log_trace "get_allowed_types_response_payload()"

    local response
    local http_code
    local payload

    log_wait "Fetching saved objects allowed types..."

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X GET \
        -H "kbn-xsrf: true" \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        "$KIBANA_HOST_ORIGIN/api/kibana/management/saved_objects/_allowed_types"
    )

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Unable to fetch allowed types. HTTP status code: $http_code"
        log_error "Response: $response"
        exit 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')

    if [[ -z "$payload" ]]; then
        log_error "Empty payload in response from the server."
        exit 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Invalid JSON response."
        log_error "Response: $payload"
        exit 1
    fi

    printf "%s" "$payload"
}

show_saved_objects_allowed_types() {
    log_trace "show_saved_objects_allowed_types()"

    local payload
    if ! payload=$(get_allowed_types_response_payload); then
        log_error "Failed to fetch allowed types."
        exit 1
    fi

    log_success "/api/kibana/management/saved_objects/_allowed_types output:\n$(echo "$payload" | jq .)"

    local allowed_types_list
    allowed_types_list=$(echo "$payload" | jq '.' | grep "\"name\":" | awk '{print $2}' | tr -d '",' | sort)
    log_empty_line

    local types=()
    IFS=$'\n' read -r -d '' -a types <<< "$allowed_types_list"

    log_info "Allowed types (from /api/kibana/management/saved_objects/_allowed_types), alphabetically sorted:\n"
    log_array_elements "true" "${types[@]}"
    log_empty_line

    # List of specialized types that are not included in the allowed types list
    SPECIALIZED_TYPES=("connector" "log-view" "rule" "ml-module" "ml-job" "timelion-sheet")

    log_info "Specialized types (not included in the allowed types list):\n"
    log_array_elements "true" "${SPECIALIZED_TYPES[@]}"
    log_empty_line

    types+=("${SPECIALIZED_TYPES[@]}")

    local sorted=()
    sorted=($(sort_array "${types[@]}"))

    log_info "Full list of types (allowed + specialized) alphabetically sorted:\n"
    log_array_elements "true" "${sorted[@]}"
    log_empty_line
}

# Fetch all saved objects of a specific type 
# The API endpoint for fetching saved objects is different for different Kibana versions
# (!) /api/saved_objects/_find is deprecated but Elastic hasn't provided an alternative yet
# See: https://github.com/elastic/kibana/issues/149988
# "/api/saved_objects/_find?type=$type&per_page=10000"
# Kibana uses: /api/kibana/management/saved_objects/_find, for example:
# /api/kibana/management/saved_objects/_find?perPage=50&page=1&fields=id&type=action&sortField=updated_at&sortOrder=desc
#
# Kibana saved objects of type "connector" are internally of type "action" ("connector" objects are stored as type "action" in Kibana saved objects)
get_saved_objects_response_payload() {
    log_trace "get_saved_objects_response_payload()"

    local response
    local http_code
    local payload
    local path

    local type="$1"
    local query_kibana_index="${2:-false}"

    if [[ -z "$type" ]]; then
        log_error "Type is required!"
        return 1
    fi

    if [[ "$query_kibana_index" != "true" && "$query_kibana_index" != "false" ]]; then
        log_error "Invalid value for query_kibana_index. Expected 'true' or 'false'."
        return 1
    fi

    if [[ "$query_kibana_index" == "true" ]]; then
        # We're using Elastic API to access Kibana index directly
        path="/.kibana*/_search"

        # The source fields that are returned for matching documents.
        # true to return the entire document source.
        # false to not return the document source.
        # <string> to return the source fields that are specified as a comma-separated list that supports wildcard (*) patterns
        local source_fields=true

        log_warning "To list all saved objects just like in Kibana >> Stack Management >> Saved objects we need to access .kibana index directly.\n\
This is not officially supported and should only be used for inspection or debugging purposes.\n\
Querying Kibana index directly will return all saved objects of type $type, even those that are technically hidden types in Kibana’s saved objects registry.\n\
Sunch hidden types might have been created by plugins etc., they have 'hiddenType' attribute set to 'true' and are not accessible via the normal REST API."

        log_wait "Fetching saved objects of type $type directly from Kibana index ($path)..."

        if [[ "$type" == "dashboard" ]]; then
            source_fields='["type", "dashboard.title", "dashboard.description"]'
        fi

        local data
        data='
        {
            "query": {
                "bool": {
                    "must": [
                        {
                            "match": {
                                "type": "'"$type"'"
                            }
                        }
                    ]
                }
            },
            "_source": '"$source_fields"',
            "size": 10000
        }'

        response=$(
            curl \
            -s \
            -w "\n%{http_code}" \
            -X POST \
            -u "$ES_USERNAME":"$ES_PASSWORD" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "$ES_HOST$path"
        )
    else
        # path="/s/default/api/saved_objects/_find?type=$type&per_page=10000"

        # currently, there is only one space in Kibana, the default one
        path="/api/kibana/management/saved_objects/_find?type=$type&perPage=1000&page=1"

        if [[ "$type" == "action" ]]; then
            # This path returns [] (0 actions, just like the original path)
            path="/api/actions"
        elif [[ "$type" == "connector" ]]; then
            # path="/api/actions"
            path="/api/actions/connectors"
            log_warning "Fetching saved objects of type $type might not work as expected. Verify objects in Kibana UI."
        elif [[ "$type" == "index-pattern" ]]; then
            # index-pattern is an alias for data-view (Index Patterns are now called Data Views)

            # https://www.elastic.co/docs/api/doc/kibana/v8/operation/operation-getalldataviewsdefault
            # This path returns 11 out of 21 data views listed in Kibana UI.
            # path="/api/data_views" 

            # Kibana request in browser
            # This path also returns 11 out of 21 data views listed in Kibana UI.
            # show_hidden, include_hidden, include_all is not valid here
            path="/api/kibana/management/saved_objects/_find?perPage=50&page=1&type=${type}&sortField=updated_at&sortOrder=desc"
            log_warning "Fetching saved objects of type $type might not work as expected. Verify objects in Kibana UI."
        # elif [[ "$type" == "dashboard" ]]; then
        #     # returns only dashboards which have "meta.hiddenType" attribute set to "false"
        #     # path="/api/kibana/management/saved_objects/_find?type=dashboard&perPage=10000&page=1&sortField=updated_at&sortOrder=desc"

        #     # By default, the Saved Objects APIs exclude hidden types, and Kibana’s REST APIs do not offer a public flag to include hidden types like "hiddenType": true
        #     # Kibana internally registers saved object types as either:
        #     # Visible types (e.g. dashboard)
        #     # Hidden types (used internally or by plugins)
        #     # Even if the object has type=dashboard, if it was created by a plugin that registers a custom hidden saved object type, it won't be accessible via the normal REST API.
        #     log_warning "Fetching saved objects of type $type might not work as expected. Verify objects in Kibana UI."
        fi

        log_wait "Fetching saved objects of type $type ($path)..."

        response=$(
            curl \
            -s \
            -w "\n%{http_code}" \
            -X GET \
            -H "kbn-xsrf: true" \
            -u "$ES_USERNAME":"$ES_PASSWORD" \
            -H "Content-Type: application/json" \
            "$KIBANA_HOST_ORIGIN$path"
        )
    fi

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Error: Unable to fetch saved objects. HTTP status code: $http_code"
        log_error "Response: $response"
        exit 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')

    if [[ -z "$payload" ]]; then
        log_error "Error: Empty payload in response from the server."
        exit 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Error: Invalid JSON response."
        log_error "Response: $payload"
        exit 1
    fi

    local objects_count
    # Check if the response JSON is an empty array or object
    if [[ "$payload" == "[]" || "$payload" == "{}" ]]; then
        objects_count=0
    else
        # if echo "$payload" | jq -e '.hits.total.value? // empty' > /dev/null; then
        if [[ "$query_kibana_index" == "true" ]]; then
            objects_count=$(echo "$payload" | jq '.hits.total.value')
        else 
            # Check if payload has .total attribute
            if echo "$payload" | jq -e 'has("total")' > /dev/null; then
                objects_count=$(echo "$payload" | jq '.total')
            else
                # If .total attribute is not present, assume that the payload is in format { "object_type": [{..}, ..] }
                # so take the first attribute and assume its value is an array
                objects_count=$(echo "$payload" | jq '.[keys_unsorted[0]] | length')
            fi
        fi
    fi

    printf "%s\n%s" "$payload" "$objects_count"
}

show_objects_of_type() {
    log_trace "show_objects_of_type()"
    local object_type
    local show_details
    local save_details_to_file
    local ret_val
    local objects_count

    while true; do
        if ! object_type=$(prompt_user_for_value "Object type (e.g. index-pattern, dashboard, etc.)"); then
            log_error "Object type is required!"
            continue
        else
            break
        fi
    done

    log_info "Object type: $object_type"
    log_empty_line

    show_details=$(prompt_user_for_confirmation "❓ Show details?" "n")

    log_info "Show details: $show_details"
    log_empty_line

    save_details_to_file=$(prompt_user_for_confirmation "❓ Save details to file?" "n")

    log_info "Save details to file: $save_details_to_file"
    log_empty_line


    log_info "About to fetch saved objects by using Kibana API"

    if ! ret_val=$(get_saved_objects_response_payload "$object_type"); then
        log_error "Failed to fetch saved objects of type $type."
        return 1
    fi

    if [[ "$show_details" == "true" ]]; then
        log_success "Response of the request to find all saved objects of type=$object_type:\n$(echo "$ret_val" | jq .)"
    fi

    if [[ "$save_details_to_file" == "true" ]]; then
        local file_name="saved_objects_${object_type}.json"
        echo "$ret_val" | jq . > "$file_name"
        log_success "Saved details to file: $file_name"
    fi

    objects_count=$(echo "$ret_val" | tail -n1)
    # payload=$(echo "$ret_val" | awk 'NR==1{print; exit}')

    # if [ "$objects_count" -gt 0 ]; then
    #     local objects_list=""

    #     # Check if payload has .saved_objects attribute
    #     if echo "$payload" | jq -e 'has("saved_objects")' > /dev/null; then
    #         # If .saved_objects attribute is present, use it
    #         objects_list=$(echo "$payload" | jq '[.saved_objects[] | {type, id, references}]')

    #     # check if payload has .hits.total.value attribute
    #     # elif echo "$payload" | jq -e 'has("hits") and .hits | has("total") and .hits.total | has("value")' > /dev/null; then
    #     elif echo "$payload" | jq -e '.hits.total.value? // empty' > /dev/null; then
    #         # If .hits.total.value attribute is present, use it
    #         # objects_list=$(echo "$payload" | jq '[.hits.hits[] | {_id, _source.type, (_source["dashboard.title"] // null)}]')
    #         objects_list=$(echo "$payload" | jq '[.hits.hits[] | {_id}]')
    #     else
    #         # If .saved_objects attribute is not present, assume that the payload is in format { "object_type": [{..}, ..] }
    #         # so take the first attribute and assume its value is an array
    #         objects_list=$(echo "$payload" | jq '.[keys_unsorted[0]][] | {id, name, title}')
    #     fi
       
    #     #   [
    #     #   {
    #     #     "type": "dashboard",
    #     #     "id": "8bc01300-bc92-11eb-855e-c5fb3014aa3b"
    #     #   },
    #     #   {
    #     #     "type": "dashboard",
    #     #     "id": "eda73750-ce39-11ed-8308-f1a02efec0fd"
    #     #   }]
    #     # objects_list=$(echo "$payload" | jq '[.saved_objects[]]')

        

    #     if [[ "$show_details" == "true" ]]; then
    #         log_success "Objects list (with only some attributes shown):\n$objects_list"
    #     else
    #         log_success "Objects list (with only some attributes shown, first 3 objects):\n$(echo "$objects_list" | jq -r '. | .[0:3]')"
    #     fi
    #     log_empty_line

    #     if [[ "$save_details_to_file" == "true" ]]; then
    #         local objects_list_file_name="saved_objects_${object_type}_compact.json"
    #         echo "$objects_list" > "$objects_list_file_name"
    #         log_success "Saved objects list to file: $objects_list_file_name"
    #     fi
    # fi

    log_info "Number of objects found: $objects_count"

    log_info "About to fetch saved objects by using Elastic API (directly from Kibana index)"

    if ! ret_val=$(get_saved_objects_response_payload "$object_type" "true"); then
        log_error "Failed to fetch saved objects of type $type."
        return 1
    fi

    if [[ "$show_details" == "true" ]]; then
        log_success "Response of the request to find all saved objects of type=$object_type:\n$(echo "$ret_val" | jq .)"
    fi

    if [[ "$save_details_to_file" == "true" ]]; then
        local file_name="saved_objects_${object_type}.kibana_index.json"
        echo "$ret_val" | jq . > "$file_name"
        log_success "Saved details to file: $file_name"
    fi

    objects_count=$(echo "$ret_val" | tail -n1)

    log_info "Number of objects found: $objects_count"
}

get_tag_object_details_response_payload() {
    log_trace "get_tag_object_details_response_payload()"

    local response
    local http_code
    local payload
    local tag_name="$1"

    if [[ -z "$tag_name" ]]; then
        log_error "Tag name is required!"
        return 1
    fi

    log_wait "Fetching tag object details for tag name: $tag_name..."

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X GET \
        -H "kbn-xsrf: true" \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        "$KIBANA_HOST_ORIGIN/api/saved_objects/_find?type=tag&search=$tag_name&search_fields=name&per_page=10000"
    )

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Error: Unable to fetch tag object details. HTTP status code: $http_code"
        log_error "Response: $response"
        return 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')

    if [[ -z "$payload" ]]; then
        log_error "Error: Empty payload in response from the server."
        return 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Error: Invalid JSON response."
        log_error "Response: $payload"
        return 1
    fi

    printf "%s" "$payload"
}

get_tag_id() {
    local tag_id
    local payload
    local tag_name="$1"

    if [[ -z "$tag_name" ]]; then
        log_error "Tag name is required!"
        return 1
    fi

    if ! payload=$(get_tag_object_details_response_payload "$tag_name"); then
        log_error "Failed to fetch $KIBANA_OBJECT_TAG tag ID."
        exit 1
    fi

    log_trace "Payload:\n$(echo "$payload" | jq .)"

    tag_id=$(echo "$payload" | jq -r '.saved_objects[0].id')
    printf "%s" "$tag_id"
}

# Fetch all saved objects of a specific type that have the <KIBANA_OBJECT_TAG> tag
# The API endpoint for fetching saved objects is different for different Kibana versions
#
# (!) /api/saved_objects/_find is deprecated but Elastic hasn't provided an alternative yet
# https://www.elastic.co/docs/api/doc/kibana/v9/operation/operation-findsavedobjects
# See: https://github.com/elastic/kibana/issues/149988
#
# In case of success, Saved Objects API returns a JSON object with the following structure:
# {
#   "page": 1,
#   "per_page": 20,
#   "total": 28,
#   "saved_objects": [
#     {
#       "type": "dashboard",
#       "id": "8bc...a3b",
#       "namespaces": [
#         "default"
#       ],
#       "attributes": {
#         "description": "",
#         "hits": 0,
#         "kibanaSavedObjectMeta": {
#           "searchSourceJSON": "{\"query\":{\"query\":\"\",\"language\":\"kuery\"},\"filter\":[]}"
#         },
#         "optionsJSON": "{\"hidePanelTitles\":false,\"useMargins\":true}",
#         "panelsJSON": "[...
#         "refreshInterval": {
#           "pause": true,
#           "value": 0
#         },
#         "timeFrom": "now-15d",
#         "timeRestore": true,
#         "timeTo": "now",
#         "title": "Data Dashboard",
#         "version": 1
#       },
#       "references": [
#         {
#           "id": "03c348a0-150d-11eb-87ef-5d40e8250222",
#           "name": "106...76cd17:panel_106d...76cd17",
#           "type": "visualization"
#         },
#        ...
#       ],
#       "migrationVersion": {
#         "dashboard": "7.10.0"
#       },
#       "coreMigrationVersion": "7.10.0",
#       "updated_at": "2023-10-01T12:00:00.000Z",
#       "version": "WzEwMTAsMV0="
#     },
#     ...
#   ],
#   "error": null
# }
get_saved_objects_with_tag_response_payload() {
    log_trace "get_saved_objects_with_tag_response_payload()"

    local response
    local http_code
    local payload
    local type="$1"
    local has_reference_value="$2"

    local path

    # Saved Objects API endpoint for fetching saved objects
    # By default it returns 1st page with 20 objects. This is why we set perPage=10000:
    path="/api/saved_objects/_find?type=$type&has_reference=$has_reference_value&per_page=10000&page=1"

    # Path used by Kibana UI to fetch saved objects
    # path="/api/kibana/management/saved_objects/_find?type=$type&hasReference=$has_reference_value&perPage=10000&page=1"

    log_wait "Using $path API to fetch saved objects of type $type with reference value $has_reference_value..."

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X GET \
        -H "kbn-xsrf: true" \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        -H "Content-Type: application/json" \
        "$KIBANA_HOST_ORIGIN$path"
    )

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Error: Unable to fetch saved objects. HTTP status code: $http_code"
        log_error "Response: $response"
        return 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')

    if [[ -z "$payload" ]]; then
        log_error "Error: Empty payload in response from the server."
        return 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Error: Invalid JSON response."
        log_error "Response: $payload"
        return 1
    fi

    printf "%s" "$payload"
}

# same as get_saved_objects_with_tag_response_payload but uses the Kibana index directly
# It is not possible to query kibana index directly in order to get saved objects by tag.
# This is because the objects stored in Kibana index don't have tag(s) attribute(s).
# Tags are stored in a separate index and are not directly associated with the saved objects.
#
# Example response of querying Kibana index directly via Elastic API:
# {
#   "took": 441,    
#   "timed_out": false,
#   "_shards": {
#     "total": 7,
#     "successful": 7,
#     "skipped": 0,
#     "failed": 0
#   },
#   "hits": {
#     "total": {
#       "value": 3,
#       "relation": "eq"
#     },
#     "max_score": 9.513762,
#     "hits": [
#       {
#         "_index": ".kibana_8.7.1_001",
#         "_id": "action:92e59890-ee53-11ed-be07-15a53c38f2ac",
#         "_score": 9.513762,
#         "_source": {
#           "action": {
#             "actionTypeId": ".server-log",
#             "name": "Monitoring: Write to Kibana log",
#             "isMissingSecrets": false,
#             "config": {},
#             "secrets": "Bw8bD8uuIrc...EXg=="
#           },
#           "type": "action",
#           "references": [],
#           "namespaces": [
#             "default"
#           ],
#           "migrationVersion": {
#             "action": "8.3.0"
#           },
#           "coreMigrationVersion": "8.7.1",
#           "updated_at": "2023-05-09T10:23:43.261Z",
#           "created_at": "2023-05-09T10:23:43.261Z"
#         }
#       },
#
# or
#
# {
#   "took": 1186,
#   "timed_out": false,
#   "_shards": {
#     "total": 7,
#     "successful": 7,
#     "skipped": 0,
#     "failed": 0
#   },
#   "hits": {
#     "total": {
#       "value": 21,
#       "relation": "eq"
#     },
#     "max_score": 6.3754406,
#     "hits": [
#       {
#         "_index": ".kibana_8.7.1_001",
#         "_id": "index-pattern:security-solution-default",
#         "_score": 6.3754406,
#         "_source": {
#           "index-pattern": {
#             "fieldAttrs": "{}",
#             "title": ".alerts-security.alerts-default,apm-*-transaction*,auditbeat-*,endgame-*,filebeat-*,logs-*,packetbeat-*,traces-apm*,winlogbeat-*,-*elastic-cloud-logs-*",
#             "timeFieldName": "@timestamp",
#             "sourceFilters": "[]",
#             "fields": "[]",
#             "fieldFormatMap": "{}",
#             "typeMeta": "{}",
#             "allowNoIndex": true,
#             "runtimeFieldMap": "{}",
#             "name": ".alerts-security.alerts-default,apm-*-transaction*,auditbeat-*,endgame-*,filebeat-*,logs-*,packetbeat-*,traces-apm*,winlogbeat-*,-*elastic-cloud-logs-*"
#           },
#           "type": "index-pattern",
#           "references": [],
#           "namespaces": [
#             "default"
#           ],
#           "migrationVersion": {
#             "index-pattern": "8.0.0"
#           },
#           "coreMigrationVersion": "8.7.1",
#           "updated_at": "2023-05-05T08:34:05.091Z",
#           "created_at": "2023-05-05T08:34:05.091Z"
#         }
#       },
#
# get_saved_objects_with_tag_from_kibana_index_response_payload() {
#     log_trace "get_saved_objects_with_tag_from_kibana_index_response_payload()"

#     local response
#     local http_code
#     local payload
#     local type="$1"
#     local tag_name="$2"

#     local path
#     path="/.kibana*/_search"

#     log_wait "Using $path API to fetch saved objects of type $type with tag $tag_name..."

#     local data
#     data='
#     {
#         "query": {
#             "bool": {
#                 "must": [
#                     {
#                         "term": {
#                             "type": "'"$type"'"
#                         }
#                     },
#                     {
#                         "match": {
#                             "'"$type"'.tags": "'"$tag_name"'"
#                         }
#                     }
#                 ]
#             }
#         },
#         "_source": true,
#         "size": 10000
#     }'

#     response=$(
#         curl \
#         -s \
#         -w "\n%{http_code}" \
#         -X GET \
#         -H "kbn-xsrf: true" \
#         -u "$ES_USERNAME":"$ES_PASSWORD" \
#         -H "Content-Type: application/json" \
#         "$ES_HOST$path" \
#         -d "$data"
#     )

#     http_code=$(echo "$response" | tail -n1)

#     if [[ "$http_code" -ne 200 ]]; then
#         log_error "Error: Unable to fetch saved objects. HTTP status code: $http_code"
#         log_error "Response: $response"
#         exit 1
#     fi

#     payload=$(echo "$response" | awk 'NR==1{print; exit}')

#     if [[ -z "$payload" ]]; then
#         log_error "Error: Empty payload in response from the server."
#         exit 1
#     fi

#     if ! echo "$payload" | jq empty; then
#         log_error "Error: Invalid JSON response."
#         log_error "Response: $payload"
#         exit 1
#     fi

#     printf "%s" "$payload"
# }

# Function to fetch saved objects of a specific type that have the specified tag
# Arguments:
#   $1: Type of the saved object (e.g. index-pattern, dashboard, etc.)
#   $2: has_reference_value (URI-encoded value which contains Tag ID)
# Returns:
#   JSON payload containing the saved objects of the specified type and tag
#   If no saved objects are found, returns an empty string
#   If an error occurs, logs the error and exits with a non-zero status
#   The function uses the /api/saved_objects/_find API endpoint to fetch the saved objects
# get_objects_list() {
#     log_trace "get_objects_list()"

#     local type="$1"
#     local has_reference_value="$2"

#     if [[ -z "$type" ]]; then
#         log_error "Type is required!"
#         return 1
#     fi

#     if [[ -z "$has_reference_value" ]]; then
#         log_error "has_reference_value is required!"
#         return 1
#     fi

#     local payload
#     if ! payload=$(get_saved_objects_with_tag_response_payload "$type" "$has_reference_value"); then
#         log_error "Failed to fetch saved objects of type $type and tag id $tag_id."
#         return 1
#     fi

#     printf "%s" "$payload"
# }

resolve_saved_object() {
    log_trace "resolve_saved_object()"

    local object_type="$1"
    local object_id="$2"

    if [[ -z "$object_type" ]]; then
        log_error "Object type is required!"
        return 1
    fi

    if [[ -z "$object_id" ]]; then
        log_error "Object ID is required!"
        return 1
    fi
    log_info "Resolving saved object of type $object_type with ID $object_id..."

    local response
    local http_code
    local payload

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X GET \
        -H "kbn-xsrf: true" \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        "$KIBANA_HOST_ORIGIN/api/saved_objects/$object_type/$object_id"
    )

    http_code=$(echo "$response" | tail -n1)
    if [[ "$http_code" -ne 200 ]]; then
        log_error "Error: Unable to resolve saved object. HTTP status code: $http_code"
        log_error "Response: $response"
        return 1
    fi
    payload=$(echo "$response" | awk 'NR==1{print; exit}')
    if [[ -z "$payload" ]]; then
        log_error "Error: Empty payload in response from the server."
        return 1
    fi
    if ! echo "$payload" | jq empty; then
        log_error "Error: Invalid JSON response."
        log_error "Response: $payload"
        return 1
    fi
    # log_success "Resolved saved object:\n$(echo "$payload" | jq .)"

    printf "%s" "$payload"
}

verify_references() {
    log_trace "verify_references()"

    local objects_list="$1"

    if [[ -z "$objects_list" ]]; then
        log_error "Objects list is required!"
        return 1
    fi

    # Extract all references from the objects list into an array of unique reference objects.
    # Verify if the reference objects exist in the saved objects list.
    # If don't exist, find the parent objects in the objects list and print them with warning message.

    local references
    references=$(echo "$objects_list" | jq -r '.[] | .references[] | {type: .type, id: .id, name: .name}' | jq -s 'unique_by(.id) | sort_by(.name)')
    log_info "References:\n$references"

    # Use jq to loop through each element
    echo "$references" | jq -c '.[]' | while read -r item; do
        id=$(echo "$item" | jq -r '.id')
        name=$(echo "$item" | jq -r '.name')
        type=$(echo "$item" | jq -r '.type')

        log_info "Processing item:\n\tID: $id\n\tName: $name\n\tType: $type"

        # Check if the reference exists in the objects list

        local payload

        if ! payload=$(resolve_saved_object "$type" "$id"); then
            log_error "Failed to resolve saved object of type $type and ID $id."

            # If the reference object does not exist, find the parent object in the objects list
            local parent_objects
            parent_objects=$(echo "$objects_list" | jq -r --arg id "$id" '.[] | select(.references[]? | .id == $id) | {type: .type, id: .id}' | jq -s 'unique_by(.id)')
           
            if [[ -n "$parent_objects" ]]; then
                log_warning "Parent objects of the missing reference found:\n$parent_objects"
                log_warning "Importing these objects into another Kibana instance might fail due to missing reference."
                log_warning "Consider removing the reference from the parent objects before importing or don't import these parent objects at all."
            else
                log_error "No parent objects found for reference ID $id."
            fi
           
            continue
        fi

        log_success "Resolved saved object (payload, truncated):\n$(echo "$payload" | jq . | head -n 5)"

        # Check if the reference object itself has references and if so, resolve them too
        # Check if payload contains .references attribute
        if echo "$payload" | jq -e 'has("references")' > /dev/null; then
            # If .references attribute is present, read references and verify them
            # Bash doesn't support block-level scope within if statements. Local variables in Bash can only be scoped at the function level.
            local references_objects_list
            references_objects_list=$(echo "$payload" | jq '. | [{type: .type, id: .id, references: .references}]')
            log_info "References list:\n$references_objects_list"
            verify_references "$references_objects_list"
        else
            log_warning "No references found in the resolved saved object."
        fi
    done

    log_empty_line
}

probe_export_saved_objects() {
    log_trace "probe_export_saved_objects()"

    local type="$1"
    local tag_name="$2"
    local objects_list="$3"
    local includeReferencesDeep="$4"

    local response
    local http_code
    local payload

    local timestamp
    local response_file_name
    local export_file_name

    if [[ -z "$type" ]]; then
        log_error "Type is required."
        exit 1
    fi

    if [[ -z "$objects_list" ]]; then
        log_error "Empty objects_list JSON: $objects_list"
        exit 1
    fi

    if ! echo "$objects_list" | jq empty 2>/dev/null; then
        log_error "Invalid JSON in objects_list: $objects_list"
        exit 1
    fi

    if [[ -z "$includeReferencesDeep" ]]; then
        includeReferencesDeep=false
    fi

    # excludeExportDetails:
    # - default is false
    # example: {"exportedCount": 1, "missingRefCount": 0, "missingReferences": []}
    local http_post_data="{
        \"objects\":$objects_list,
        \"excludeExportDetails\": false,
        \"includeReferencesDeep\": $includeReferencesDeep
    }"

    log_trace "HTTP POST data:\n$http_post_data"

    local url="$KIBANA_HOST_ORIGIN/api/saved_objects/_export"
    log_wait "Sending request to $url to export saved objects of type $type and tag $tag_name..."

    response=$(curl \
        -s \
        -w "\n%{http_code}" \
        -X POST \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        -H "kbn-xsrf: string" \
        -H "Content-Type: application/json; Elastic-Api-Version=2023-10-31" \
        -d "$http_post_data" \
        "$KIBANA_HOST_ORIGIN/api/saved_objects/_export")

    # Enable only for testing purposes
    # echo "$response" | jq . > "$response_file_name"

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Error: Unable to probe export saved objects of type $type. HTTP status code: $http_code"
        log_error "Response: $response"
        exit 1
    fi

    # Remove the last line (HTTP status code) from the response
    payload=$(echo "$response" | sed '$d')
    # payload=$(echo "$response" | head -n -1 | jq -c '.')

    if [[ -z "$payload" ]]; then
        log_error "Error: Empty payload in response from the server."
        exit 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Error: Invalid JSON response."
        log_error "Response: $payload"
        exit 1
    fi

    # Extract the last line from the payload
    local export_details
    export_details=$(echo "$payload" | tail -n1)
    # log_info "Export details:\n$export_details"

    # Return export details
    printf "%s" "$export_details"
}

# _export API requires the objects list to be in the following format:
# [
#   {
#     "type": "dashboard",
#     "id": "8bc01300-...-c5fb3014aa3b"
#   },
#   {
#     "type": "index-pattern",
#     "id": "36ea7ea0-e7e4-11ec-92b0-b5f4ac305a0c"
#   }
# ]
# The references attribute is not needed for the export.
# The export API will automatically resolve the references when importing the objects.
export_saved_objects() {
    log_trace "export_saved_objects()"

    local type="$1"
    local tag_name="$2"
    local objects_list="$3"
    local includeReferencesDeep="$4"
    local excludeExportDetails="$5"

    local response
    local http_code
    local payload

    local timestamp
    local response_file_name
    local export_file_name

    if [[ -z "$type" ]]; then
        log_error "Type is required."
        exit 1
    fi

    if [[ -z "$objects_list" ]]; then
        log_error "Empty objects_list JSON: $objects_list"
        exit 1
    fi

    if ! echo "$objects_list" | jq empty 2>/dev/null; then
        log_error "Invalid JSON in objects_list: $objects_list"
        exit 1
    fi

    if [[ -z "$excludeExportDetails" ]]; then
        excludeExportDetails=false
    fi

    if [[ -z "$includeReferencesDeep" ]]; then
        includeReferencesDeep=false
    fi

    timestamp=$(date '+%Y-%m-%d-%H-%M-%S')
    response_file_name="${ENV}_${type}_${tag_name}_${timestamp}.export_response.json"
    export_file_name="${ENV}_${type}_${tag_name}_${timestamp}.ndjson"


    # excludeExportDetails:
    # - default is false
    # example: {"exportedCount": 1, "missingRefCount": 0, "missingReferences": []}
    local http_post_data="{
        \"objects\":$objects_list,
        \"excludeExportDetails\": $excludeExportDetails,
        \"includeReferencesDeep\": $includeReferencesDeep
    }"

    log_trace "HTTP POST data:\n$http_post_data"

    local url="$KIBANA_HOST_ORIGIN/api/saved_objects/_export"
    log_wait "Sending request to $url to export saved objects of type $type and tag $tag_name..."

    response=$(curl \
        -s \
        -w "\n%{http_code}" \
        -X POST \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        -H "kbn-xsrf: string" \
        -H "Content-Type: application/json; Elastic-Api-Version=2023-10-31" \
        -d "$http_post_data" \
        "$KIBANA_HOST_ORIGIN/api/saved_objects/_export")

    # Enable only for testing purposes
    echo "$response" | jq . > "$response_file_name"

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Error: Unable to export saved objects of type $type. HTTP status code: $http_code"
        log_error "Response: $response"
        exit 1
    fi

    # Remove the last line (HTTP status code) from the response
    payload=$(echo "$response" | sed '$d')
    # payload=$(echo "$response" | head -n -1 | jq -c '.')

    if [[ -z "$payload" ]]; then
        log_error "Error: Empty payload in response from the server."
        exit 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Error: Invalid JSON response."
        log_error "Response: $payload"
        exit 1
    fi

    if [[ $excludeExportDetails == false ]]; then
        # Extract the last line from the payload
        local export_details
        export_details=$(echo "$payload" | tail -n1)
        log_info "Export details:\n$export_details"

        # Remove the last line from the payload
        payload=$(echo "$payload" | sed '$d')

        # export_details is a JSON object with the following structure (example):
        # {"excludedObjects":[],"excludedObjectsCount":0,"exportedCount":58,"missingRefCount":1,"missingReferences":[{"id":"aaea9d30-fc48-11ec-92b0-b5f4ac305a0c","type":"index-pattern"}]}
    fi

    # log_trace "Payload:\n$(echo "$payload" | jq .)"

    # Save the exported objects to a file.
    # The file will be in the NDJSON format, which is a newline-delimited JSON format.
    # Each line in the file must be a valid JSON object so don't use jq to pretty print the JSON.
    # This format is used by Kibana for importing and exporting saved objects.
    echo "$payload" > "$export_file_name"

    # Return the name of the export file
    printf "%s" "$export_file_name"
}

show_objects_with_tag() {
    log_trace "show_objects_with_tag()"

    local object_type
    local tag_name
    local save_details_to_file
    local create_export_ndjson_file

    object_type=$(prompt_user_for_value "Object type (e.g. index-pattern, dashboard, etc.)")
    log_info "Object type: $object_type"

    tag_name=$(prompt_user_for_value "Tag name")
    log_info "Tag name: $tag_name"

    save_details_to_file=$(prompt_user_for_confirmation "❓ Save details to file?" "n")
    log_info "Save details to file: $save_details_to_file"

    create_export_ndjson_file=$(prompt_user_for_confirmation "❓ Create export ndjson file?" "n")
    log_info "Create export ndjson file: $create_export_ndjson_file"

    local tag_id

    if ! tag_id=$(get_tag_id "$tag_name"); then
        log_error "Failed to fetch the tag ID."
        return 1
    fi

    log_success "Found Tag ID: $tag_id"

    local has_reference_value
    # /api/saved_objects/_find requires has_reference to have a URI-encoded value
    has_reference_value=$(echo '[{"type":"tag","id":"'"$tag_id"'"}]' | jq -sRr @uri)
    log_info "has_reference_value: $has_reference_value"

    log_wait "Fetching saved objects of type $object_type and tag $tag_name..."

    local payload=""
    if ! payload=$(get_saved_objects_with_tag_response_payload "$object_type" "$has_reference_value"); then
        log_error "Failed to fetch saved objects of type $object_type and tag id $tag_id."
        return 1
    fi

    if [[ -z "$payload" ]]; then
        log_warning "No saved objects of type $object_type and tag id $tag_id found"
        log_empty_line
        return 0
    fi

    log_info "Payload (truncated):\n$(echo "$payload" | jq . | head -n 50)"

    if [[ $save_details_to_file == "true" ]]; then
        local payload_file_name="saved_objects_${object_type}_tag_${tag_name}.payload.json"
        echo "$payload" | jq . > "$payload_file_name"
        log_success "Saved objects response payload to file: $payload_file_name"
    fi

    local objects_count
    objects_count=$(echo "$payload" | jq '.total')
    log_info "Number of saved objects returned: $objects_count"

    local object_names
    # object_names=$(echo "$payload" | jq -r '.saved_objects[] | {id: .id, title: .attributes.title}')
    object_names=$(echo "$payload" | jq -r '.saved_objects[] | .attributes.title')

    log_info "List of saved object names:\n$object_names"
    log_empty_line

    local objects_list=""

    if [ "$objects_count" -gt 0 ]; then
        # Create compact list of objects like this:
        # [
        #     {
        #         "type": "dashboard",
        #         "id": "8bc01300-...-c5fb3014aa3b",
        #         "references": [
        #             {
        #                "name": "kibanaSavedObjectMeta.searchSourceJSON.filter[0].meta.index",
        #                "type": "index-pattern",
        #                "id": "36ea7ea0-e7e4-11ec-92b0-b5f4ac305a0c"
        #             },
        #             ...
        #         ]
        #     },
        #     ...
        # ]
        objects_list=$(echo "$payload" | \
            jq '[.saved_objects[] | {title: .attributes.title, type: .type, id: .id, references: .references}]')
        log_info "objects_list: \n$(echo "$objects_list" | jq .)"

        if [[ "$create_export_ndjson_file" == "true" ]]; then
            local objects_list_for_export
            local includeReferencesDeep=true
            local export_details

            objects_list_for_export=$(echo "$payload" | jq '[.saved_objects[] | {type: .type, id: .id}]')

            if ! export_details=$(probe_export_saved_objects "$object_type" "$tag_name" "$objects_list_for_export" \
                "$includeReferencesDeep"); then
                log_error "Failed to probe export saved objects of type $object_type and tag name $tag_name."
                return 1
            fi

            log_info "Export details:\n$export_details"

            # Verify if export_details contains "missingRefCount" and "missingReferences"
            # If "missingRefCount" is greater than 0, it means that there are missing references in the export.

            local missing_ref_count
            missing_ref_count=$(echo "$export_details" | jq '.missingRefCount')

            if [[ "$missing_ref_count" -gt 0 ]]; then
                log_warning "Export contains objects with missing references. Proceeding with import might fail so such objects will be omitted from the export."
                log_warning "Missing references count: $missing_ref_count"

                local missing_references
                missing_references=$(echo "$export_details" | jq '.missingReferences')
                log_warning "Missing references:\n$missing_references"

                # It is not possible to remove missing references from objects in objects_list.
                # This is because only object ids and type are sent to export API which then verifies references.
                # All we can do is to remove objects from objects_list which have missing references in the list of
                # references.

                # First, let's list objects that will be removed
                local objects_to_remove
                objects_to_remove=$(echo "$objects_list" | jq -r --argjson missing_references "$missing_references" \
                    '[.[] | select(any(.references[]; .id == $missing_references[].id))]')
                log_warning "Objects to be removed:\n$objects_to_remove"

                # Now, let's remove them from objects_list
                log_info "Removing objects with missing references from objects_list..."
                # iterate through missing_references and from objects_list remove any object which has missing reference
                # in the list of references
                # and save the remaining objects to a new list
                objects_list=$(echo "$objects_list" | jq -r --argjson missing_references "$missing_references" \
                    '[.[] | select(all(.references[]; .id != $missing_references[].id))]')
                log_info "objects_list (after removing objects with missing references):\n$objects_list"

                objects_list_for_export=$(echo "$objects_list" | jq '[.[] | {type: .type, id: .id}]')
            fi

            log_info "objects_list_for_export:\n$objects_list_for_export"

            # print the count of elements in objects_list_for_export
            local filtered_objects_count
            filtered_objects_count=$(echo "$objects_list_for_export" | jq '. | length')
            log_info "Number of objects in objects_list_for_export: $filtered_objects_count"

            local export_file_name

            local excludeExportDetails=false
            if ! export_file_name=$(export_saved_objects "$object_type" "$tag_name" "$objects_list_for_export" \
                "$includeReferencesDeep" "$excludeExportDetails"); then
                log_error "Failed to export saved objects of type $object_type and tag name $tag_name."
                return 1
            fi
            
            log_success "Exported objects to file: $export_file_name"
        fi

        # verify_references "$objects_list"
    fi

    # if [[ $save_details_to_file == "true" ]]; then
    #     local objects_list_file_name="saved_objects_${object_type}_tag_${tag_name}.json"
    #     echo "$objects_list" | jq . > "$objects_list_file_name"
    #     log_success "Saved objects list to file: $objects_list_file_name"
    # fi

    # if ! payload=$(get_saved_objects_with_tag_from_kibana_index_response_payload "$object_type" "$tag_name"); then
    #     log_error "Failed to fetch saved objects of type $object_type and tag name $tag_name."
    #     return 1
    # fi

    # if [[ -z "$payload" ]]; then
    #     log_warning "No saved objects of type $object_type and tag name $tag_name found"
    #     log_empty_line
    #     return 0
    # fi

    # log_info "Payload (truncated):\n$(echo "$payload" | jq . | head -n 50)"
    # log_info "Number of saved objects returned: $(echo "$payload" | jq '.hits.total.value')"
    log_empty_line
}

# overwrite=false parameter ensures that objects with the same IDs will not be replaced
#
# Output in case of some objects' import errors out is in format:
# {
#   "successCount": 55,
#   "success": false,
#   "warnings": [],
#   "successResults": [
#     {
#       "type": "index-pattern",
#       "id": "filebeat-*",
#       "meta": {
#         "title": "filebeat-*",
#         "icon": "indexPatternApp"
#       },
#       "managed": false
#     },
#     {
#       "type": "visualization",
#       "id": "03c348a0-150d-11eb-87ef-5d40e8250222",
#       "meta": {
#         "title": "Engagement",
#         "icon": "visualizeApp"
#       },
#       "managed": false
#     },
#     ...
#   ],
#   "errors": [
#     {
#       "id": "eda73750-ce39-11ed-8308-f1a02efec0fd",
#       "type": "dashboard",
#       "meta": {
#         "title": "twitter-engagement-report",
#         "icon": "dashboardApp"
#       },
#       "error": {
#         "type": "missing_references",
#         "references": [
#           {
#             "type": "index-pattern",
#             "id": "aaea9d30-fc48-11ec-92b0-b5f4ac305a0c"
#           }
#         ]
#       }
#     },
#     ...
#   ]
# }
import_saved_objects() {
    log_trace "import_saved_objects()"

    local filename="$1"
    local overwrite="$2"
    local request_url

    if [[ -z "$filename" ]]; then
        log_error "Filename is required."
        exit 1
    fi

    if [[ ! -f "$filename" ]]; then
        log_error "File $filename does not exist."
        exit 1
    fi

    if [[ ! -r "$filename" ]]; then
        log_error "File $filename is not readable."
        exit 1
    fi

    if [[ ! -s "$filename" ]]; then
        log_error "File $filename is empty."
        exit 1
    fi

    if [[ -z "$overwrite" ]]; then
        overwrite=false
    fi

    request_url="$KIBANA_HOST_TARGET/api/saved_objects/_import?overwrite=$overwrite"
    log_info "Request URL: $request_url"

    local proceed
    proceed=$(prompt_user_for_confirmation "❓ Proceed with import?" "n")
    if [[ "$proceed" != "true" ]]; then
        log_warning "Import cancelled by user."
        return 1
    fi

    log_wait "Sending request to $request_url to import saved objects from file $filename..."

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X POST \
        -u "$ES_USERNAME":"$ES_PASSWORD" -s \
        -H "kbn-xsrf: true" \
        -H "Content-Type: multipart/form-data" \
        -F "file=@${filename}" \
        "$request_url")

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Error: Unable to import saved objects of type $type. HTTP status code: $http_code"
        log_error "Response: $response"
        return 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')

    if [[ -z "$payload" ]]; then
        log_error "Error: Empty payload in response from the server."
        return 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Error: Invalid JSON response."
        log_error "Response: $payload"
        return 1
    fi

    printf "%s" "$payload"
}

import_saved_objects_handler() {
    log_trace "import_saved_objects_handler()"
    local filename
    local overwrite

    filename=$(prompt_user_for_value "File name (e.g. export.ndjson)")
    log_info "File name: $filename"

    overwrite=$(prompt_user_for_confirmation "❓ Overwrite existing objects?" "n")
    if [[ "$overwrite" != "true" ]]; then
        overwrite=false
    fi
    log_info "Overwrite existing objects: $overwrite"

    local payload
    if ! payload=$(import_saved_objects "$filename" "$overwrite"); then
        log_error "Failed to import saved objects from file $filename."
        return 1
    fi

    log_trace "import_saved_objects response payload:\n$(echo "$payload" | jq .)"
    log_empty_line

    if [ "$(echo "$payload" | jq -r '.success')" == true ]; then
        log_success "Successfully imported saved objects form file $filename"
    else
        log_error "Failed to import saved objects from file $filename"
    fi
}

show_saved_object() {
    local object_type
    local object_id

    object_type=$(prompt_user_for_value "Object type (e.g. index-pattern, dashboard, etc.)")
    log_info "Object type: $object_type"
    object_id=$(prompt_user_for_value "Object ID")
    log_info "Object ID: $object_id"

    local response
    local http_code
    local payload
    local path

    path="/api/saved_objects/$object_type/$object_id"

    log_wait "Using $path to fetch saved object of type $object_type with ID $object_id..."

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X GET \
        -H "kbn-xsrf: true" \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        "$KIBANA_HOST_ORIGIN$path"
    )
    http_code=$(echo "$response" | tail -n1)
    if [[ "$http_code" -ne 200 ]]; then
        log_error "Unable to fetch saved object. HTTP status code: $http_code"
        log_error "Response: $response"
        return 1
    fi
    payload=$(echo "$response" | awk 'NR==1{print; exit}')
    if [[ -z "$payload" ]]; then
        log_error "Empty payload in response from the server."
        return 1
    fi
    if ! echo "$payload" | jq empty; then
        log_error "Invalid JSON response."
        log_error "Response: $payload"
        return 1
    fi
    # log_success "$path output:\n$(echo "$payload" | jq .)"
    log_success "$path output:\n"
    log_string "$(echo "$payload" | jq .)"
    log_empty_line
    

    if [[ "$object_type" == "dashboard" ]]; then
        log_info "attributes.panelsJSON:\n"
        log_string "$(echo "$payload" | jq -r '.attributes.panelsJSON' | jq .)"
    fi
    log_empty_line
}

show_data_views() {
    log_trace "show_data_views()"

    local response
    local http_code
    local payload
    local path

    # path="/api/data_views/"
    path="/api/saved_objects/_find?type=index-pattern&per_page=10000"

    log_warning "Using Saved Objects API returns only data views with 'hiddenType' set to 'false'.\n
To list all data views just like in Kibana >> Stack Management >> Data views we need to access .kibana index directly (use 'show objects of type' menu item)."

    log_wait "Fetching data views (formerly known as 'index patterns')..."

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X GET \
        -H "kbn-xsrf: true" \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        -H 'Content-Type: application/json' \
        "$KIBANA_HOST_ORIGIN$path"
    )

    http_code=$(echo "$response" | tail -n1)
    if [[ "$http_code" -ne 200 ]]; then
        log_error "Unable to fetch data views. HTTP status code: $http_code"
        log_error "Response: $response"
        return 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')
    if [[ -z "$payload" ]]; then
        log_error "Empty payload in response from the server."
        return 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Invalid JSON response."
        log_error "Response: $payload"
        return 1
    fi

    # printf "%s" "$payload"
    log_success "$path output:\n$(echo "$payload" | jq .)"
    log_empty_line

    log_info "Total number of data views: $(echo "$payload" | jq '.total')"
    log_empty_line
    log_info "List of data views (compact):\n$(echo "$payload" | \
        jq -r '.saved_objects[] | {id:"\(.id)",Name:"\(.attributes.name)",Title:"\(.attributes.title)"}')"
    log_empty_line
}

show_data_view() {
    log_trace "show_data_view()"

    local data_view_id
    data_view_id=$(prompt_user_for_value "Data view ID")
    log_info "Data view ID: $data_view_id"

    local response
    local http_code
    local payload
    # local path="/api/data_views/_find?id=$data_view_id"


    local path="/.kibana*/_search"
    local source_fields=true
    local type="index-pattern"

    log_wait "Fetching saved objects of type $type with id $data_view_id directly from Kibana index ($path)..."

    local data
    data='
    {
        "query": {
            "bool": {
                "must": [
                    {
                        "term": {
                            "type": "index-pattern"
                        }
                    },
                    {
                        "term": {
                            "_id": "index-pattern:'"$data_view_id"'"
                        }
                    }
                ]
            }
        },
        "_source": '"$source_fields"',
        "size": 10000
    }'

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X POST \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "$ES_HOST$path"
    )

    http_code=$(echo "$response" | tail -n1)
    if [[ "$http_code" -ne 200 ]]; then
        log_error "Unable to fetch data view. HTTP status code: $http_code"
        log_error "Response: $response"
        return 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')
    if [[ -z "$payload" ]]; then
        log_error "Empty payload in response from the server."
        return 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Invalid JSON response."
        log_error "Response: $payload"
        return 1
    fi

    # printf "%s" "$payload"
    log_success "$path output:\n$(echo "$payload" | jq .)"
    log_empty_line
}

show_available_kibana_privileges(){ 
    local path="/api/security/privileges"

    log_wait "Fetching available Kibana privileges ($path)..."

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X GET \
        -H "kbn-xsrf: true" \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        "$KIBANA_HOST_ORIGIN$path"
    )

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Request failed. HTTP status code: $http_code"
        log_error "Response: $response"
        return 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')

    if [[ -z "$payload" ]]; then
        log_error "Empty payload in response from the server."
        return 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Invalid JSON response."
        log_error "Response: $payload"
        return 1
    fi

    log_success "Available Kibana privileges:\n$(echo "$payload" | jq .)"
    log_empty_line
}

show_user_privileges() {
    local path="/api/security/role"

    log_wait "Fetching Kibana privileges for user $ES_USERNAME ($path)..."

    response=$(
        curl \
        -s \
        -w "\n%{http_code}" \
        -X GET \
        -H "kbn-xsrf: true" \
        -u "$ES_USERNAME":"$ES_PASSWORD" \
        "$KIBANA_HOST_ORIGIN$path"
    )

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Request failed. HTTP status code: $http_code"
        log_error "Response: $response"
        return 1
    fi

    payload=$(echo "$response" | awk 'NR==1{print; exit}')

    if [[ -z "$payload" ]]; then
        log_error "Empty payload in response from the server."
        return 1
    fi

    if ! echo "$payload" | jq empty; then
        log_error "Invalid JSON response."
        log_error "Response: $payload"
        return 1
    fi

    log_success "User $ES_USERNAME privileges:\n$(echo "$payload" | jq .)"
    log_empty_line
}

kibana_menu(){
    local menu_options=(
        "show all spaces"
        "show current space"
        "show saved objects allowed types"
        "show objects of type"
        "show/export objects with tag"
        "import saved objects (ndjson file)"
        "show saved object"
        "show data views"
        "show data view"
        "show available Kibana privileges"
        "show user privileges"
        "EXIT"
    )

    while true; do
        show_menu_select_message "kibana"

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "show all spaces")
                        show_all_spaces
                        ;;  
                    "show current space")
                        show_current_space
                        ;;
                    "show saved objects allowed types")
                        show_saved_objects_allowed_types
                        ;;
                    "show objects of type")
                        show_objects_of_type
                        ;;
                    "show/export objects with tag")
                        show_objects_with_tag
                        ;;
                    "import saved objects (ndjson file)")
                        import_saved_objects_handler
                        ;;
                    "show saved object")
                        show_saved_object
                        ;;
                    "show data views")
                       show_data_views
                        ;;
                    "show data view")
                        show_data_view
                        ;;
                    "show available Kibana privileges")
                        show_available_kibana_privileges
                        ;;
                    "show user privileges")
                        show_user_privileges
                        ;;
                    "EXIT")
                        # log_finish "Exiting the submenu..."
                        return 0
                        ;;
                    *)
                        log_error "Invalid option"
                        ;;
                esac
                break
            else
                log_error "Invalid selection. Please choose a valid option."
            fi
        done
    done
}

print_usage() {
    echo "Usage: $0 <environment>"
    echo "environment: test, prod"
}

main() {
    log_info "Bash version: $BASH_VERSION"

    VERBOSE=false
    ENV=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose)
                VERBOSE=true
                shift # Move to the next argument
                ;;
            test|prod)
                ENV="$1"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Validate mandatory arguments
    if [[ -z "$ENV" ]]; then
        print_usage
        exit 1
    fi

    if [[ "$ENV" == "prod" ]]; then
       echo ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
       log_warning "Warning: You are running this script on a production environment!"
       echo ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
       echo
    fi

    # log_info "VERBOSE: $VERBOSE"
    log_info "ENV: $ENV"

    # Look for .env file in the script's directory
    ENV_FILE="$SCRIPT_DIR/.env.$ENV"

    # Check if the corresponding .env file exists
    if [ -f "$ENV_FILE" ]; then
        log_wait "Loading environment variables from $ENV_FILE..."
        source "$ENV_FILE"
    else
        log_error_and_exit "Error: Environment file $ENV_FILE not found!"
    fi

    # log_info "ES_USERNAME=$ES_USERNAME"
    # log_info "ES_PASSWORD=$ES_PASSWORD"
    # log_info "KIBANA_USERNAME=$KIBANA_USERNAME"
    # log_info "KIBANA_PASSWORD=$KIBANA_PASSWORD"
    log_info "ES_HOST=$ES_HOST"
    log_info "KIBANA_HOST_ORIGIN=$KIBANA_HOST_ORIGIN"
    log_info "KIBANA_HOST_TARGET=$KIBANA_HOST_TARGET"

    if [[ ! $KIBANA_HOST_ORIGIN =~ ^https:// ]]; then
        KIBANA_HOST_ORIGIN="https://$KIBANA_HOST_ORIGIN"
    fi

    if [[ ! $KIBANA_HOST_TARGET =~ ^https:// ]]; then
        KIBANA_HOST_TARGET="https://$KIBANA_HOST_TARGET"
    fi

    main_menu
}

main "$@"
