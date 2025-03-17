#!/usr/bin/env bash

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

get_cluster_state() {
    # Get the state of the cluster
    local response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_cluster/state?pretty" \
        -H "Content-Type: application/json")
    echo $response
}

show_cluster_state() {
    cluster_state=$(get_cluster_state)
    # (!) Very verbose output
    echo
    echo "Cluster state:"
    echo $cluster_state | jq .
}

show_cluster_settings() {
    # Get the settings of the cluster
    local response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_cluster/settings?pretty" \
        -H "Content-Type: application/json")
    echo $response | jq .
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
    read -p "Enter settings type (persistent/transient): " settings_type

    if [[ -z "$settings_type" ]]; then
        echo "Settings type is required!"
        return 1
    fi

    # Ask user for the setting key
    local setting_key=""
    read -p "Enter setting key: " setting

    if [[ -z "$setting" ]]; then
        echo "Setting key is required!"
        return 1
    fi

    # Ask user for the setting value
    local setting_value=""
    read -p "Enter setting value: " setting_value

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
        -u "$USERNAME:$PASSWORD" \
        -X PUT \
        "$ES_HOST/_cluster/settings" \
        -H "Content-Type: application/json" \
        -d \
        "$request_body")
    echo $response | jq .
}

check_cluster_health() {
    echo && echo "Checking cluster health..."
    # Check the health of the cluster
    curl \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_cluster/health?pretty" \
        -H "Content-Type: application/json"
}

get_nodes_info() {
    # redirect the output to stderr to enforce flush as otherwise
    # this string will also be returned by the function
    echo && echo "Getting nodes info..." >&2
    # Get the IDs of the nodes in the cluster
    local response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_nodes?pretty" \
        -H "Content-Type: application/json")

    echo $response
}

show_nodes_info() {
    nodes_info=$(get_nodes_info)
    echo && echo "Nodes info:" && echo
    # (!) Very verbose output
    echo $nodes_info | jq .
}

get_nodes_ids() {
    # redirect the output to stderr to enforce flush as otherwise
    # this string will also be returned by the function
    echo && echo "Getting node IDs..." >&2
    # Get the IDs of the nodes in the cluster
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/nodes?v&full_id=true&h=id" \
        -H "Content-Type: application/json")

    echo $response
}

show_nodes_ids() {
    nodes_ids=$(get_nodes_ids)
    echo && echo "Nodes IDs:" && echo
    echo $nodes_ids
}

get_node_settings() {
    # redirect the output to stderr to enforce flush as otherwise
    # this string will also be returned by the function
    echo && echo "Getting node settings..." >&2
    # Get the settings of the nodes in the cluster
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_nodes/settings?pretty" \
        -H "Content-Type: application/json")

    echo $response
}

show_nodes_settings() {
    node_settings=$(get_node_settings)
    echo && echo "Nodes settings:" && echo
    # (!) Very verbose output
    # echo $node_settings | jq
    echo $node_settings | jq -r '.nodes | to_entries[] | "\(.key): \(.value.settings.path.logs)"'
}

# In case of success, the response will be:
# <snapshot_repository_1> <backend>
# <snapshot_repository_2> <backend>
get_snapshot_repositories() {
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
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
        local response=$(verify_repository "$repository")
        echo $response | jq .
    done
}

verify_repository() {
    local repository=$1
    local response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X POST \
        "$ES_HOST/_snapshot/$repository/_verify?pretty")
    echo "$response"
}

get_shards_recovery_status() {
    # _recovery endpoint returns information about ongoing and completed shard recoveries for one or more indices.
    curl \
    -s \
    -u "$USERNAME:$PASSWORD" \
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
        -u "$USERNAME:$PASSWORD" \
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
        -u "$USERNAME:$PASSWORD" \
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
        echo $repo
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

# Function to get all SLM (Snapshot Lifecycle Management) policies dynamically
get_slm_policies() {
    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_slm/policy?pretty" \
        | jq -r 'keys[]'
}

show_slm_policies_details() {
    echo
    echo "Snapshot Lifecycle Management Policies:"
    echo
    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_slm/policy?pretty" \
        | jq .
}

get_latest_snapshot_for_policy() {
    local snapshot_repository="$1"
    local policy_name="$2"

    local response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_snapshot/$snapshot_repository/_all" \
        | jq -r \
            --arg policy "$policy_name" \
            '.snapshots | map(select(.metadata.policy == $policy)) | max_by(.start_time_in_millis) | .snapshot'
    )

    echo "$response"
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
      -u "$USERNAME:$PASSWORD" \
      -X GET \
      "$ES_HOST/_index_template" \
      -H "Content-Type: application/json"
  )

  for index in "${indices[@]}"; do
    echo "Index: $index"

    # templates=$(curl \
    #     -s \
    #     -u "$USERNAME:$PASSWORD" \
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
    #     -u "$USERNAME:$PASSWORD" \
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
        #     -u "$USERNAME:$PASSWORD" \
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
        read -p "Enter data stream name: " data_stream_name
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
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/$data_stream_name" \
        -H "Content-Type: application/json"
    )

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

show_templates_for_index() {
    local index_name=$1
    echo >&2
    echo "Index templates" >&2
    echo >&2

    # If index name is not provided, prompt user for it

    if [[ -z "$index_name" ]]; then
        read -p "Enter index name: " index_name
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
        -u "$USERNAME:$PASSWORD" \
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
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream" \
        -H "Content-Type: application/json"
    )

    all_index_templates=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
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
                #     -u "$USERNAME:$PASSWORD" \
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
        echo $index_template
    done

    # Print the unique array of component templates
    echo
    echo
    echo "Component templates which are used in index streams supporting data stream(s) (unique values):"
    echo
    for component_template in "${unique_array_of_component_templates[@]}"; do
        echo $component_template
    done
}

show_ilm_policy_names_for_indices() {
    local indices=("$@")

    declare -A unique_ilm_policy_names
    unique_array_of_ilm_policy_names=()

    echo "List of indices and their ILM policy names:"

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
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
            echo "  No ILM policy found for index: $index"
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
        echo $ilm_policy_name
    done
}

show_latest_snapshot_details() {
    local snapshot_repositories=$(get_snapshot_repositories)
    # echo && echo "Snapshot repositories response:" && echo "$snapshot_repositories"
    local snapshot_repositories_array=($(echo "$snapshot_repositories" | awk '{print $1}'))
    if [ ${#snapshot_repositories_array[@]} -eq 0 ]; then
        echo "No snapshot repositories found!"
        return 1
    fi

    # User selects which repository to use
    local snapshot_repository=""
    echo
    echo "Select a snapshot repository:"
    select snapshot_repository in "${snapshot_repositories_array[@]}"; do
        if [[ -n "$snapshot_repository" ]]; then
            echo "Selected snapshot repository: $snapshot_repository"
            break
        else
            echo "Invalid selection. Please choose a valid repository."
        fi
    done

    # Get policy names dynamically
    local policies=($(get_slm_policies))

    if [ ${#policies[@]} -eq 0 ]; then
        echo "No snapshot policies found!"
        return 1
    fi

    # User selects which policy to use
    echo
    echo "Select a policy for which you want to get the latest snapshot info from:"
    select policy in "${policies[@]}"; do
        if [[ -n "$policy" ]]; then
            echo "Fetching latest snapshot for policy: $policy..."
            latest_snapshot=$(get_latest_snapshot_for_policy "$snapshot_repository" "$policy")

            if [[ -z "$latest_snapshot" ]]; then
                echo "No snapshots found for policy: $policy"
                exit 1
            fi

            echo
            echo "Latest snapshot found: $latest_snapshot"
            echo "Snapshot details:"
            echo

            response=$(curl \
                -s \
                -u "$USERNAME:$PASSWORD" \
                -X GET \
                "$ES_HOST/_snapshot/$snapshot_repository/$latest_snapshot?pretty" \
                -H "Content-Type: application/json")

            echo $response | jq .

            echo
            echo "Snapshot indices (sorted by name):"
            echo
            echo $response | jq -r '.snapshots[0].indices[]' | sort
            echo

            echo
            echo "Snapshot indices (sorted by name) with supporting index and component templates:"
            echo
            local indices=($(echo $response | jq -r '.snapshots[0].indices[]' | sort))
            # TODO: Uncomment the following line
            # show_templates_for_indices "${indices[@]}"

            echo
            echo "Snapshot data streams (sorted by name):"
            echo
            echo $response | jq -r '.snapshots[0].data_streams[]' | sort

            echo
            echo "Snapshot data streams (sorted by name) with supporting index and component templates:"
            echo
            local data_streams=($(echo $response | jq -r '.snapshots[0].data_streams[]' | sort))
            show_templates_for_data_streams "${data_streams[@]}"

            echo
            echo "Snapshot ILM policy names for indices in this snapshot:"
            show_ilm_policy_names_for_indices "${indices[@]}"

            # Todo: Find out why request below returns 504 Gateway Time-out
            # By then, to prevent waiting for timeout, we're returning at this point.
            return 0

            echo
            echo "Snapshot status:"
            echo
            response=$(curl \
                -s \
                -u "$USERNAME:$PASSWORD" \
                -X GET \
                "$ES_HOST/_snapshot/$snapshot_repository/$latest_snapshot/_status?ignore_unavailable=true" \
                -H "Content-Type: application/json"
            )

            # Check if response contains "504 Gateway Time-out" or "503 Service Unavailable"
            if [[ $response == *"504 Gateway Time-out"* ]] || [[ $response == *"503 Service Unavailable"* ]]; then
                echo
                echo "Response: $response"
                echo "Snapshot status is not available. Please try again later."
                return 1
            fi

            # Response can be quite verbose. Enable printing it only for debugging purposes.
            # echo $response | jq .

            echo
            echo "Snapshot indices (sorted by name) (from _status endpoint):"
            echo
            echo $response | jq -r '.snapshots[0].indices | keys[]' | sort
            echo

            break
        else
            echo "Invalid selection. Please choose a valid policy."
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
    read -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        exit 1
    fi

    echo "Fetching number of documents in index: $index_name..." >&2

    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
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

    read -p "Enter how many documents to fetch from the index (default is 10): " documents_count

    if [[ -n "$documents_count" ]]; then
        echo "Fetching $documents_count documents in index: $index_name..." >&2
    else
        documents_count=10
        echo "Fetching $documents_count documents in index: $index_name..." >&2
    fi

    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
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
    read -p "Enter settings to modify (e.g. \"index.number_of_replicas\":0 or \"index.lifecycle.name\":\"my-metrics@custom\"): " settings

    if [[ -z "$settings" ]]; then
        echo "Settings are required!"
        return 1
    fi

    echo "Settings to modify: $settings"

    local settings_json=$(convert_to_json $settings)

    # Prompt user for index name, ENTER for providing the file path containing the the list of indices
    local index_name=""
    local indices_file_path=""

    read -p "Enter index name or ENTER to provide file path containing the list of indices: " index_name

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

        indices=($output)

        # Check if array is empty
        if [[ ${#indices[@]} -eq 0 ]]; then
            echo "No index names found in file: $index_name"
            return 1
        fi
    else
        indices=($index_name)
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

    read -p "Do you want to proceed? (y/n): " confirm

    if [[ "$confirm" != "y" ]]; then
        echo "Modifying of indices' settings cancelled."
        return 1
    fi

    # Modify settings for each index
    for index in "${indices[@]}"; do
        echo "Modifying settings for index: $index..."

        response=$(curl \
            -s \
            -u "$USERNAME:$PASSWORD" \
            -X PUT \
            "$ES_HOST/$index/_settings?pretty=true" \
            -H 'Content-Type: application/json' \
            -d \
            "$settings_json"
        )

        echo $response | jq .
    done
}

show_mapping_for_index() {
    local index_name=""
    echo >&2
    echo "Index mapping" >&2
    echo >&2

    # Prompt user for index name
    read -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        exit 1
    fi

    echo "Fetching mapping for index: $index_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_mapping?pretty=true" \
        -H 'Content-Type: application/json')
    echo $response | jq .
}

show_all_mappings_in_cluster() {
    echo >&2
    echo "All mappings in the cluster" >&2
    echo >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_mapping?pretty=true" \
        -H 'Content-Type: application/json')
    echo $response | jq .
}

close_index() {
    local index_name=""
    echo >&2
    echo "Close index" >&2
    echo >&2

    # Prompt user for index name
    read -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        exit 1
    fi

    echo "Closing index: $index_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X POST \
        "$ES_HOST/$index_name/_close?pretty=true" \
        -H 'Content-Type: application/json')
    echo $response | jq .
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
    #     -u "$USERNAME:$PASSWORD" \
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
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/indices?v&expand_wildcards=all&pretty&s=index" \
        -H "Content-Type: application/json")

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
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/indices?v&expand_wildcards=open,closed&h=index,status&s=index" \
        -H "Content-Type: application/json"

    # Show hidden indices only
    echo
    echo "List of hidden index names only:"
    echo
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
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
        -u "$USERNAME:$PASSWORD" \
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

show_indices_with_ilm_errors() {
    echo
    echo "Fetching indices with ILM errors..."

    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/.*,*/_ilm/explain?only_managed=false&pretty&only_errors=true" \
        -H "Content-Type: application/json" \
        | jq -r \
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
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$TARGET_ES_HOST/_aliases?pretty"
    )

    aliases=$(echo $response | jq --arg index "$index" '.[$index].aliases? | select(. != null and . != {}) | keys[]')
    if [[ -z "$aliases" ]]; then
        echo "No aliases found."
    else
        echo "Aliases: "
        echo $aliases | jq .
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
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream?pretty&expand_wildcards=all"
    )

    local data_streams=$(echo $response | jq --arg index "$index" '.data_streams[] | select(.indices[].index_name == $index) | .name')

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
    echo "Show index details" >&2
    echo >&2

    # Prompt user for index name
    read -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        return 1
    fi

    echo "Finding index (using CAT API): $index_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
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
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_settings?pretty" \
        -H 'Content-Type: application/json')
    echo $response | jq .

    local creation_date=$(echo $response | jq -r '.[].settings.index.creation_date')
    echo
    echo "Human readable creation date:" $(date -r $(($creation_date/1000)) "+%Y-%m-%d %H:%M:%S %Z")
    echo

    show_templates_for_index "$index_name"

    show_aliases_for_index "$index_name"

    show_data_stream_for_index "$index_name"

    show_index_ilm_details "$index_name"
}

show_data_stream_details() {
    local data_stream_name=""
    echo >&2
    echo "Show data stream details" >&2
    echo >&2

    # Prompt user for data stream name
    read -p "Enter data stream name: " data_stream_name

    if [[ -z "$data_stream_name" ]]; then
        echo "Data stream name is required!"
        return 1
    fi

    echo "Finding data stream: $data_stream_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/$data_stream_name?pretty" \
        -H 'Content-Type: application/json')

    echo
    echo $response | jq .

    echo "Currently active (write) backing index for this data stream is the latest index."

    # response=$(curl \
    #     -s \
    #     -u "$USERNAME:$PASSWORD" \
    #     -X GET \
    #     "$ES_HOST/_data_stream/$data_stream_name?human=true" \
    #     -H 'Content-Type: application/json')
    # echo
    # echo $response | jq .

    # Fetch and show data stream backing indices
    echo
    show_supporting_indices_for_data_stream "$data_stream_name"

    echo
    echo "Supporting index and component templates:"
    echo
    local data_streams=("$data_stream_name")
    show_templates_for_data_streams "${data_streams[@]}"
}

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
    read -p "Enter data stream name: " data_stream_name

    if [[ -z "$data_stream_name" ]]; then
        echo "Data stream name is required!"
        return 1
    fi

    echo "Rollover data stream: $data_stream_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X POST \
        "$ES_HOST/$data_stream_name/_rollover?pretty" \
        -H 'Content-Type: application/json')

    echo
    echo $response | jq .
}

add_index_to_data_stream() {
    local data_stream_name=""
    local index_name=""
    echo >&2
    echo "Add index to data stream" >&2
    echo >&2

    # Prompt user for data stream name
    read -p "Enter data stream name: " data_stream_name

    if [[ -z "$data_stream_name" ]]; then
        echo "Data stream name is required!"
        return 1
    fi

    # Prompt user for index name
    read -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        return 1
    fi

    echo "Adding index: $index_name to data stream: $data_stream_name..." >&2

    # double quotes are required for variable expansion
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
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

    echo
    echo $response | jq .
}

show_index_ilm_details() {
    local index_name="$1"
    echo >&2
    echo "Index ILM details" >&2
    echo >&2

    # If index name is not provided, prompt user for it
    if [[ -z "$index_name" ]]; then
        read -p "Enter index name: " index_name
        if [[ -z "$index_name" ]]; then
            echo "Index name is required!"
            return 1
        fi
    fi

    echo "Fetching ILM details for index: $index_name..." >&2
    echo >&2

    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_ilm/explain?pretty"
}

move_index_to_ilm_step() {
    local index_name=""

    echo >&2
    echo "Move index to ILM step" >&2
    echo >&2

    # Prompt user for index name
    read -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        return 1
    fi

    local current_phase current_action current_step_name

    read -p "Enter current phase: " current_phase
    if [[ -z "$current_phase" ]]; then
        echo "Current phase is required!"
        return 1
    fi

    read -p "Enter current action: " current_action
    if [[ -z "$current_action" ]]; then
        echo "Current action is required!"
        return 1
    fi

    read -p "Enter current step name: " current_step_name
    if [[ -z "$current_step_name" ]]; then
        echo "Current step name is required!"
        return 1
    fi

    local next_phase next_action next_step_name

    read -p "Enter next phase: " next_phase
    if [[ -z "$next_phase" ]]; then
        echo "Next phase is required!"
        return 1
    fi
    read -p "Enter next action: " next_action
    if [[ -z "$next_action" ]]; then
        echo "Next action is required!"
        return 1
    fi

    read -p "Enter next step name: " next_step_name
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
    read -p "Do you want to proceed? (y/n): " confirm

    if [[ "$confirm" != "y" ]]; then
        echo "Moving index to ILM step cancelled."
        return 1
    fi

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X POST \
        "$ES_HOST/_ilm/move/$index_name?pretty" \
        -H 'Content-Type: application/json' \
        -d "$post_data")

    echo
    echo $response | jq .
}

show_ilm_policies() {
    echo && echo "Fetching ILM policies..."

    # Prompt user whether to show names only
    local names_only=""
    read -p "Show ILM policy names only? (true/false; hit ENTER for false): " names_only
    if [[  -z "$names_only" ]]; then
        names_only="false"
    fi

    # Get the ILM policies in the cluster
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_ilm/policy?pretty" \
        -H "Content-Type: application/json")

    if [[ "$names_only" == "true" ]]; then
        echo $response | jq -r 'keys[]'
    else
        echo $response | jq .
        echo

        # Use jq to get the Policy name and policy._meta.managed fields, all in one line but padded so that the columns align
        # For some policies, .value.policy._meta.managed field is missing, so we need to handle that case
        echo $response | jq -r \
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
    echo $response | jq -r \
    '
        to_entries[] |
        select(.value.policy._meta.managed == true) |
        .key
    '

    # Show unmanaged ILM policies only
    echo
    echo "Unmanaged ILM policies:"
    echo
    echo $response | jq -r \
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
    read -p "Enter ILM policy name: " policy_name

    if [[ -z "$policy_name" ]]; then
        echo "ILM policy name is required!"
        return 1
    fi

    echo "Finding ILM policy: $policy_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_ilm/policy/$policy_name?pretty" \
        -H 'Content-Type: application/json')

    echo $response | jq .
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
    read -p "Enter ILM policy name: " policy_name

    if [[ -z "$policy_name" ]]; then
        echo "ILM policy name is required!"
        return 1
    fi

    echo "Exporting ILM policy: $policy_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_ilm/policy/$policy_name?pretty=true" \
        -H 'Content-Type: application/json')

    # echo $response | jq -r 'to_entries[] | .value.policy'
    # echo $response | jq -r 'to_entries[] | .value.policy' > "$policy_name.json"
    echo $response | jq -r '{ policy: .[keys[0]].policy }'
    echo $response | jq -r '{ policy: .[keys[0]].policy }' > "$policy_name.json"

    echo "ILM policy $policy_name exported to $policy_name.json"
}

import_ilm_policy() {
    local policy_name=""
    echo >&2
    echo "Import ILM policy" >&2
    echo >&2

    # Prompt user for policy name
    read -p "Enter ILM policy name: " policy_name

    if [[ -z "$policy_name" ]]; then
        echo "ILM policy name is required!"
        return 1
    fi

    echo "Importing ILM policy: $policy_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X PUT \
        "$ES_HOST/_ilm/policy/$policy_name" \
        -H 'Content-Type: application/json' \
        -d "@$policy_name.json")

    echo $response | jq .
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
    read -p "Enter ILM policy name: " policy_name

    if [[ -z "$policy_name" ]]; then
        echo "ILM policy name is required!"
        return 1
    fi

    echo "Deleting ILM policy: $policy_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X DELETE \
        "$ES_HOST/_ilm/policy/$policy_name?pretty=true" \
        -H 'Content-Type: application/json')

    echo $response | jq .
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
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/*?expand_wildcards=all&pretty" \
        -H "Content-Type: application/json")

    echo
    echo "Data streams (names only):"
    echo
    echo $response | jq -r '.data_streams[].name'


    echo
    echo "Data streams with supporting indices:"
    echo
    echo $response | jq -r \
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
    read -p "Enter the path to the file: " file_path

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
    read -p "Enter index name (use wildcard names to match multiple indices; ENTER to load index names from a file): " index_name

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

        read -p "Do you want to proceed? (y/n): " confirm

        if [[ "$confirm" != "y" ]]; then
            echo "Closing of indices cancelled."
            return 1
        fi

        # Close indices

        for index in "${indices[@]}"; do
            echo "Closing index: $index..." >&2

            curl \
                -s \
                -u "$USERNAME:$PASSWORD" \
                -X POST \
                "$ES_HOST/$index/_close?pretty=true" \
                -H 'Content-Type: application/json'
        done
    else
        echo "Closing index/indices: $index_name..." >&2

        curl \
            -s \
            -u "$USERNAME:$PASSWORD" \
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
    read -p "Enter index name (use wildcard names to match multiple indices; ENTER to load index names from a file): " index_name

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

        read -p "Do you want to proceed? (y/n): " confirm

        if [[ "$confirm" != "y" ]]; then
            echo "Deletion of indices cancelled."
            return 1
        fi

        # Delete indices

        for index in "${indices[@]}"; do
            echo "Deleting index: $index..." >&2

            curl \
                -s \
                -u "$USERNAME:$PASSWORD" \
                -X DELETE \
                "$ES_HOST/$index?pretty=true" \
                -H 'Content-Type: application/json'
        done
    else
        echo "Deleting index/indices: $index_name..." >&2

        curl \
            -s \
            -u "$USERNAME:$PASSWORD" \
            -X DELETE \
            "$ES_HOST/$index_name?pretty=true" \
            -H 'Content-Type: application/json'
    fi
}

delete_data_stream() {
    local data_stream_name=""
    echo >&2
    echo "Data stream deletion" >&2
    echo >&2

    # Prompt user for data stream name
    read -p "Enter data stream name: " data_stream_name

    if [[ -z "$data_stream_name" ]]; then
        echo "Data stream name is required!"
        exit 1
    fi

    echo "Deleting data stream: $data_stream_name..." >&2

    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X DELETE \
        "$ES_HOST/_data_stream/$data_stream_name?pretty=true" \
        -H 'Content-Type: application/json'
}

show_component_templates() {

    # Prompt user whether to show names only
    local names_only=""
    read -p "Show component template names only? (true/false): " names_only
    
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
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_component_template?pretty" \
        -H "Content-Type: application/json")
    echo $response | jq -r "$jq_query" | sort
}

show_component_template() {
    local component_template_name=""
    echo >&2
    echo "Component template details" >&2
    echo >&2

    # Prompt user for component template name
    read -p "Enter component template name: " component_template_name

    if [[ -z "$component_template_name" ]]; then
        echo "Component template name is required!"
        return 1
    fi

    echo "Finding component template: $component_template_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_component_template/$component_template_name?pretty=true" \
        -H 'Content-Type: application/json')

    echo $response | jq .
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
    read -p "Enter component template name: " component_template_name

    if [[ -z "$component_template_name" ]]; then
        echo "Component template name is required!"
        return 1
    fi

    echo "Exporting component template: $component_template_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_component_template/$component_template_name?pretty=true" \
        -H 'Content-Type: application/json')

    echo $response | jq .component_templates[0].component_template
    echo $response | jq .component_templates[0].component_template > "$component_template_name.json"

    echo "Component template $component_template_name exported to $component_template_name.json"
}

import_component_template() {
    local component_template_name=""
    local component_template_file=""
    echo >&2
    echo "Component template import" >&2
    echo >&2

    # Prompt user for component template name
    read -p "Enter component template name: " component_template_name

    if [[ -z "$component_template_name" ]]; then
        echo "Component template name is required!"
        return 1
    fi

    # Prompt user for component template file
    read -p "Enter component template file: " component_template_file

    if [[ -z "$component_template_file" ]]; then
        echo "Component template file is required!"
        return 1
    fi

    echo "Importing component template: $component_template_name from file: $component_template_file..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X PUT \
        "$ES_HOST/_component_template/$component_template_name?pretty=true" \
        -H 'Content-Type: application/json' \
        -d "@$component_template_file")

    echo $response | jq .
    echo "Component template imported: $component_template_name"
}

show_index_templates() {

    # Prompt user whether to show names only
    local names_only=""
    read -p "Show index template names only? (true/false): " names_only
    
    if [[ -z "$names_only" ]]; then
        echo "Names only value is required!"
        return 1
    fi

    # Echo names_only value
    # echo "Names only: $names_only"

    local used_component_templates=false

    if [[ "$names_only" == "true" ]]; then
        # Prompt user whether to show used component templates
        
        read -p "Show used component templates? (true/false): " used_component_templates

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
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template?pretty" \
        -H "Content-Type: application/json")
    echo "Index templates count:" $(echo $response | jq -r '.index_templates | length')

    # Get the index templates in the cluster
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template?pretty" \
        -H "Content-Type: application/json")

    echo && echo "Fetching index templates..." >&2
    
    # Echo response depending on names_only and used_component_templates values
    if [[ "$names_only" == "true" ]]; then
        if [[ "$used_component_templates" == "true" ]]; then
            # echo $response | jq -r '.index_templates | to_entries[] | sort_by(.value.name) | .value.name + "\n" + (.value.index_template.composed_of[] | map("\t" + .) | join("\n") | .[])'
            echo $response | jq -r '.index_templates | sort_by(.name) | .[] | .name, "\tComponent template(s):", (.index_template.composed_of | map("\t\t" + .) | .[]), "\tIndex patterns:", (.index_template.index_patterns | map("\t\t" + .) | .[]), "\n"'
        else
            echo $response | jq -r '.index_templates | to_entries[] | .value.name' | sort
        fi
    else
        echo $response | jq .
    fi
}

show_index_template() {
    local index_template_name=""
    echo >&2
    echo "Index template details" >&2
    echo >&2

    # Prompt user for index template name
    read -p "Enter index template name: " index_template_name

    if [[ -z "$index_template_name" ]]; then
        echo "Index template name is required!"
        return 1
    fi

    echo "Fetching index template: $index_template_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template/$index_template_name?pretty=true" \
        -H 'Content-Type: application/json')
    echo $response | jq .

    # Extract index template patterns
    local index_patterns=$(echo $response | jq -r '.index_templates[0].index_template.index_patterns[]')

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
                -u "$USERNAME:$PASSWORD" \
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
    read -p "Enter index template name: " index_template_name

    if [[ -z "$index_template_name" ]]; then
        echo "Index template name is required!"
        return 1
    fi

    echo "Exporting index template: $index_template_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_index_template/$index_template_name?pretty=true" \
        -H 'Content-Type: application/json')

    echo $response | jq .index_templates[0].index_template
    echo $response | jq .index_templates[0].index_template > "$index_template_name.json"

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
    read -p "Enter index template name: " index_template_name

    if [[ -z "$index_template_name" ]]; then
        echo "Index template name is required!"
        return 1
    fi

    # Prompt user for index template file
    read -p "Enter index template file: " index_template_file

    if [[ -z "$index_template_file" ]]; then
        echo "Index template file is required!"
        return 1
    fi

    echo "Importing index template: $index_template_name from file: $index_template_file..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X PUT \
        "$ES_HOST/_index_template/$index_template_name?pretty=true" \
        -H 'Content-Type: application/json' \
        --data-binary "@$index_template_file")
    echo $response | jq .

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
    read -p "Enter index template name (use wildcard names to match multiple index templates): " index_template_name

    if [[ -z "$index_template_name" ]]; then
        echo "Index template name is required!"
        exit 1
    fi

    echo "Deleting index template: $index_template_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X DELETE \
        "$ES_HOST/_index_template/$index_template_name?pretty=true" \
        -H 'Content-Type: application/json')
    echo $response | jq .
}

delete_component_template() {
    local component_template_name=""
    echo >&2
    echo "Component template deletion" >&2
    echo >&2

    # Prompt user for component template name
    read -p "Enter component template name: " component_template_name

    if [[ -z "$component_template_name" ]]; then
        echo "Component template name is required!"
        exit 1
    fi

    echo "Deleting component template: $component_template_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X DELETE \
        "$ES_HOST/_component_template/$component_template_name?pretty=true" \
        -H 'Content-Type: application/json')
    echo $response | jq .
}

show_aliases() {
    echo
    echo "Fetching aliases (_alias endpoint)..." >&2
    echo

    # This will list all aliases in the cluster and their associated indices. 
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_alias?pretty" \
        -H "Content-Type: application/json")
    echo $response | jq --sort-keys .


    echo
    echo "Fetching aliases (_aliases endpoint)..." >&2
    echo
    echo "List of indices with aliases:"

    # Get the aliases in the cluster
    # By default, _aliases does not return aliases for hidden indices (indices starting with .).
    # To include hidden indices in the response, use expand_wildcards=all to include hidden indices
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_aliases?expand_wildcards=all&pretty" \
        -H "Content-Type: application/json")
    echo $response | jq --sort-keys .

    # echo
    # echo "Number of indices with 'aliases' field present:"
    # echo $response | jq -r '. | to_entries | length'

    # echo
    # echo "Number of indices with aliases:"
    # echo $response | jq -r '. | to_entries | map(select(.value.aliases | length > 0)) | length'

    # Print only index names with aliases, in a table format
    echo
    echo "List of index names with aliases:"
    echo "(Note that the same index can have multiple aliases and hence can be listed multiple times)"
    # 
    # echo "(Also note that hidden indices are not included in the response)"
    echo
    echo $response | jq -r \
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
    #     -u "$USERNAME:$PASSWORD" \
    #     -X GET \
    #     "$ES_HOST/.*,*/_alias?pretty&expand_wildcards=all" \
    #     -H "Content-Type: application/json")
    # echo $response | jq --sort-keys .

    # echo
    # echo "Number of aliases:"
    # echo $response | jq -r '. | to_entries | length'

    echo
    echo "List of aliases (CAT API):"
    echo
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
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
    read -p "Enter alias name: " alias_name

    if [[ -z "$alias_name" ]]; then
        echo "Alias name is required!"
        return 1
    fi

    echo "Finding alias: $alias_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_alias/$alias_name?pretty=true" \
        -H 'Content-Type: application/json')
    echo $response | jq .
}

create_alias(){
    local alias_name=""
    local index_name=""
    echo >&2
    echo "Create alias" >&2
    echo >&2

    # Prompt user for alias name
    read -p "Enter alias name: " alias_name

    if [[ -z "$alias_name" ]]; then
        echo "Alias name is required!"
        return 1
    fi

    # Prompt user for index name
    read -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        return 1
    fi

    echo "Creating alias: $alias_name for index: $index_name..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X PUT \
        "$ES_HOST/_alias/$alias_name/$index_name?pretty=true" \
        -H 'Content-Type: application/json')
    echo $response | jq .
}

add_alias_to_index(){
    local index_name=""
    local alias_input=""
    echo >&2
    echo "Add alias to index" >&2
    echo >&2

    # Prompt user for index name
    read -p "Enter the index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        return 1
    fi

    # Prompt user for alias name
    read -p "Enter the alias name: " alias_input

    if [[ -z "$alias_input" ]]; then
        echo "Alias name is required!"
        return 1
    fi

    # Prompt user for is_write_index
    # While an alias can point to multiple indices for read operations, only one index
    # can be designated as the write index for an alias. This is specified using the
    # "is_write_index" parameter when setting up the alias.

    local is_write_index=""
    read -p "Is this a write index? (true/false; hit ENTER for false): " is_write_index

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
    echo $request_body | jq .

    # Prompt user whether to go ahead with the operation
    local proceed=""
    read -p "Proceed with adding alias to index? (y/n): " proceed

    if [[ "$proceed" != "y" ]]; then
        echo "Operation aborted!"
        return 1
    fi

    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
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
        -u "$USERNAME:$PASSWORD" \
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
    echo $response | jq -r '.hits.total.value'

    echo && echo "Fleet agents id:"
    echo $response | jq -r '.hits.hits[] | ._id'
}

# The same as list_agents, but with using a different endpoint
# Use ?kuery=status:offline to get offline agents
list_agents_kibana_endpoint() {
    echo && echo "Fetching Fleet agents (using Kibana API)..."

    # Prompt user whether to show verbose output
    local verbose_output="false"
    read -p "Show verbose output? (true/false; hit ENTER for default value - false): " verbose_output

    if [[ -z "$verbose_output" ]]; then
        verbose_output="false"
    fi

    echo "Verbose output: $verbose_output"

    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X GET \
        "$KIBANA_HOST/api/fleet/agents?perPage=100" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true')

    if [[ "$verbose_output" == "true" ]]; then
        echo $response | jq .
    else
         echo $response | jq -r '.list[] | .id + " " + .status'
    fi
}

get_agent_ids() {
    echo && echo "Fetching Fleet agent IDs (using Kibana API)..." >&2

    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X GET \
        "$KIBANA_HOST/api/fleet/agents?perPage=100" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true')

    local agent_ids_array=($(echo $response | jq -r '.list[] | .id'))
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
        echo $agent_id
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
        "$KIBANA_HOST/api/fleet/agents/bulk_unenroll" \
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
        "$KIBANA_HOST/api/fleet/fleet_server_hosts" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true')

    echo $response | jq .
}

delete_fleet_server_host() {
    echo && echo "Deleting Fleet server host (using Kibana API)..."

    local fleet_server_host_id=""
    echo
    echo "Fleet server host deletion"
    echo

    # Prompt user for fleet server host ID
    read -p "Enter Fleet server host ID: " fleet_server_host_id

    if [[ -z "$fleet_server_host_id" ]]; then
        echo "Fleet server host ID is required!"
        return 1
    fi

    echo "Deleting Fleet server host: $fleet_server_host_id..." >&2

    curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X DELETE \
        "$KIBANA_HOST/api/fleet/fleet_server_hosts/$fleet_server_host_id" \
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
    read -p "Enter Fleet server host ID: " fleet_server_host_id

    if [[ -z "$fleet_server_host_id" ]]; then
        echo "Fleet server host ID is required!"
        return 1
    fi

    echo "Updating Fleet server host: $fleet_server_host_id..." >&2

    # Prompt user for host URLs (strings separated by space)
    read -p "Enter Fleet server host URL: " fleet_server_host
    
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
    read -p "Is this the default Fleet server host? (true/false): " default_host

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
        "$KIBANA_HOST/api/fleet/fleet_server_hosts/$fleet_server_host_id" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true' \
        -d \
        "$request_body")

    echo $response | jq .
}

show_fleet_outputs() {
    echo && echo "Fetching Fleet outputs (using Kibana API)..."

    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X GET \
        "$KIBANA_HOST/api/fleet/outputs" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true')

    echo $response | jq .
}

update_fleet_output() {
    echo && echo "Updating Fleet output (using Kibana API)..."

    local fleet_output_id=""
    echo
    echo "Fleet output update"
    echo

    # Prompt user for fleet output ID
    read -p "Enter Fleet output ID: " fleet_output_id

    if [[ -z "$fleet_output_id" ]]; then
        echo "Fleet output ID is required!"
        return 1
    fi

    echo "Updating Fleet output: $fleet_output_id..." >&2

    # Prompt user for is_default
    read -p "Is this the default Fleet output? (true/false): " is_default

    if [[ -z "$is_default" ]]; then
        echo "is_default value is required!"
        return 1
    fi

    # Print is_default value
    echo "is_default: $is_default"

    # Prompt user for is_default_monitoring
    read -p "Is this the default monitoring output? (true/false): " is_default_monitoring

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
        "$KIBANA_HOST/api/fleet/outputs/$fleet_output_id" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true' \
        -d \
        "$request_body")
    
    echo $response | jq .
}

#
# Ingest
#

show_pipelines() {
    echo && echo "Fetching ingest pipelines..."

    # Prompt user whether to show verbose output
    local verbose="false"
    read -p "Show verbose output? (true/false; hit ENTER for false): " verbose

    if [[ -z "$verbose" ]]; then
        verbose="false"
    fi

    echo "Verbose: $verbose"
    echo

    # Get the ingest pipelines in the cluster
    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_ingest/pipeline?pretty" \
        -H "Content-Type: application/json")

    if [[ "$verbose" == "true" ]]; then
        echo $response | jq .
    else
        # echo $response | jq -r 'keys[]'
        
        # Use jq to get the pipeline name, _meta.managed and _meta.managed_by fields
        # echo $response | jq -r \
        # '
        #     to_entries[] |
        #     .key + "\n" +
        #     "\tManaged: " + (.value._meta.managed | tostring) + "\n" +
        #     "\tManaged by: " + (.value._meta.managed_by | tostring) + "\n"
        # '

        # Use jq to get the pipeline name, _meta.managed and _meta.managed_by fields, all in one line but padded so that the columns align
        echo $response | jq -r \
        '
            ["Pipeline", "Managed", "Managed By"], 
            ["--------", "-------", "----------"], 
            (to_entries[] |
            [.key, .value._meta.managed, .value._meta.managed_by]) | @tsv
        ' \
        | column -t -s $'\t'
    fi

    # Print the number of ingest pipelines
    echo
    echo "Number of ingest pipelines: $(echo $response | jq -r 'keys | length')"
}

show_pipeline_details() {
    local pipeline_id=""
    echo >&2
    echo "Ingest pipeline details" >&2
    echo >&2

    # Prompt user for pipeline ID
    read -p "Enter pipeline ID: " pipeline_id

    if [[ -z "$pipeline_id" ]]; then
        echo "Pipeline ID is required!"
        exit 1
    fi

    echo "Fetching details for pipeline: $pipeline_id..." >&2

    response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_ingest/pipeline/$pipeline_id?pretty" \
        -H "Content-Type: application/json")
    echo $response | jq .
}

show_processors() {
    echo && echo "Not implemented yet..."

    # echo && echo "Fetching ingest processors..."
    # # Get the ingest processors in the cluster
    # response=$(curl \
    #     -s \
    #     -u "$USERNAME:$PASSWORD" \
    #     -X GET \
    #     "$ES_HOST/_ingest/processor/attachment?pretty" \
    #     -H "Content-Type: application/json")
    # echo $response | jq .
}

build_menu_select_message() {
    local menu_name=$1
    echo "($ENV) [$menu_name] Please select an option:"
}

main_menu() {
    local menu_options=(
        "cluster"
        "snapshots"
        "indices"
        "fleet"
        "ingest"
        "EXIT"
    )

    while true; do
        echo
        echo $(build_menu_select_message "main menu")

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                echo "Selected option: $option"
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
                    "EXIT")
                        echo "Exiting..."
                        exit 0
                        ;;
                    *)
                        echo "Invalid option"
                        ;;
                esac
                break
            else
                echo "Invalid selection. Please choose a valid option."
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
        "nodes info (verbose)"
        "nodes_ids"
        "nodes settings (verbose)"
        "EXIT"
    )

    while true; do
        echo
        echo $(build_menu_select_message "cluster")

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                echo "Selected option: $option"
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
                    "nodes info (verbose)")
                        show_nodes_info
                        ;;
                    "nodes_ids")
                        get_nodes_ids
                        ;;
                    "nodes settings (verbose)")
                        show_nodes_settings
                        ;;
                    "EXIT")
                        echo "Exiting..."
                        return 0
                        ;;
                    *)
                        echo "Invalid option"
                        ;;
                esac
                break
            else
                echo "Invalid selection. Please choose a valid option."
            fi
        done
    done
}

COLUMNS=1 # Set the number of columns for the select menu
indices_menu() {
    local menu_options=(
        "show indices"
        "show index details"
        "show indices with ILM errors"
        "show indices with ILM errors (verbose)"
        "show index ILM details"
        "move index to ILM step"
        "show documents in index"
        "modify setting for indices"
        "close index"
        "close indices"
        "delete indices"
        "show data streams"
        "show data stream details"
        "rollover data stream"
        "add index to data stream"
        "delete data stream"
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
        echo
        echo $(build_menu_select_message "indices")

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                echo "Selected option: $option"
                case $option in
                    "show indices")
                        show_indices
                        ;;
                    "show index details")
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
                    "show data streams")
                        show_data_streams
                        ;;
                    "show data stream details")
                        show_data_stream_details
                        ;;
                    "rollover data stream")
                        rollover_data_stream
                        ;;
                    "add index to data stream")
                        add_index_to_data_stream
                        ;;
                    "delete data stream")
                        delete_data_stream
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
                        echo "Exiting..."
                        return 0
                        ;;
                    *)
                        echo "Invalid option"
                        ;;
                esac
                break
            else
                echo "Invalid selection. Please choose a valid option."
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
        "EXIT"
    )

    while true; do
        echo
        echo $(build_menu_select_message "snapshots")

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                echo "Selected option: $option"
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
                    "EXIT")
                        echo "Exiting..."
                        return 0
                        ;;
                    *)
                        echo "Invalid option"
                        ;;
                esac
                break
            else
                echo "Invalid selection. Please choose a valid option."
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
        echo
        echo $(build_menu_select_message "fleet")

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                echo "Selected option: $option"
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
                        echo "Exiting..."
                        return 0
                        ;;
                    *)
                        echo "Invalid option"
                        ;;
                esac
                break
            else
                echo "Invalid selection. Please choose a valid option."
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
        echo
        echo $(build_menu_select_message "ingest")

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                echo "Selected option: $option"
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
                        echo "Exiting..."
                        return 0
                        ;;
                    *)
                        echo "Invalid option"
                        ;;
                esac
                break
            else
                echo "Invalid selection. Please choose a valid option."
            fi
        done
    done
}

print_usage() {
    echo "Usage: $0 <environment>"
    echo "environment: test, prod"
}

main() {
    echo "Bash version: $BASH_VERSION"

    # Check if environment is provided
    if [ "$#" -ne 1 ]; then
        print_usage
        exit 1
    fi

    # Assign the first argument to ENV variable
    ENV=$1

    if [[ "$ENV" != "test" && "$ENV" != "prod" ]]; then
        echo "Invalid environment: $ENV"
        print_usage
        exit 1
    fi

    if [[ "$ENV" == "prod" ]]; then
       echo
       echo ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
       echo "Warning: You are running this script on a production environment!"
       echo ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
       echo
    fi

    # Look for .env file in the script's directory
    ENV_FILE="$SCRIPT_DIR/.env.$ENV"

    # Check if the corresponding .env file exists
    if [ -f "$ENV_FILE" ]; then
        echo "Loading environment variables from $ENV_FILE..."
        source "$ENV_FILE"
    else
        echo "Error: Environment file $ENV_FILE not found!"
        exit 1
    fi

    # echo "USERNAME=$USERNAME"
    # echo "PASSWORD=$PASSWORD"
    # echo "KIBANA_USERNAME=$KIBANA_USERNAME"
    # echo "KIBANA_PASSWORD=$KIBANA_PASSWORD"
    echo "ES_HOST=$ES_HOST"
    echo "KIBANA_HOST=$KIBANA_HOST"

    if [[ ! $KIBANA_HOST =~ ^https:// ]]; then
        KIBANA_HOST="https://$KIBANA_HOST"
    fi

    main_menu
}

main "$@"
