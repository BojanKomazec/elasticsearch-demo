#!/bin/bash

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

check_cluster_health() {
    echo && echo "Checking cluster health..."
    # Check the health of the cluster
    curl \
        -s \
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

get_shards_status() {
    curl \
    -s \
    -u "$USERNAME:$PASSWORD" \
    -X GET \
    "$ES_HOST/_recovery" \
    | jq -r \
    'keys[] as $index | .[$index].shards | keys[] as $shard_arr_index | "\($index) \($shard_arr_index) \(.[$shard_arr_index].stage) \(.[$shard_arr_index].index.size.percent) \(.[$shard_arr_index].index.files.percent)"' | column -t
}

shards_status_report() {
    shards_status=$(get_shards_status)
    echo && echo "Shards status (per index):" && echo "$shards_status"
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

            break
        else
            echo "Invalid selection. Please choose a valid policy."
        fi
    done
}

show_documents_in_index() {
    local index_name=""
    local documents_count=10000

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

    read -p "Enter how many documents to fetch from the index (default is 10000): " documents_count

    if [[ -n "$documents_count" ]]; then
        echo "Fetching $documents_count documents in index: $index_name..." >&2
    else
        documents_count=10000
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

show_indices() {
    echo && echo "Fetching indices..." >&2
    # Get the indices in the cluster
    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_cat/indices?v&expand_wildcards=all&pretty&s=index" \
        -H "Content-Type: application/json"
}

# | jq -r '.indices | to_entries[] | select(.value.step == "ERROR") | .key'
show_indices_with_ilm_errors_detailed() {
    echo
    echo "Fetching indices with ILM errors..."

    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_all/_ilm/explain?pretty&only_errors=true"
}

#  | jq -r '.indices | keys[]'
show_indices_with_ilm_errors() {
    echo
    echo "Fetching indices with ILM errors..."

    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_all/_ilm/explain?pretty&only_errors=true" \
        -H "Content-Type: application/json" \
        | jq -r \
        '
            .indices |
            to_entries[] |
            .value.index + "\n" +
            "\tReason: " + .value.step_info.reason + "\n"
        '
}

show_index_ilm_details() {
    local index_name=""
    echo >&2
    echo "Index ILM details" >&2
    echo >&2

    # Prompt user for index name
    read -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        exit 1
    fi

    echo "Fetching ILM details for index: $index_name..." >&2
    echo >&2

    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/$index_name/_ilm/explain?pretty"
}

show_ilm_policies() {
    echo && echo "Fetching ILM policies..." >&2
    # Get the ILM policies in the cluster
    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_ilm/policy?pretty" \
        -H "Content-Type: application/json" \
        | jq -r 'keys[]'
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
    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$ES_HOST/_data_stream/*?expand_wildcards=all&pretty" \
        -H "Content-Type: application/json" \
        | jq -r \
        '
            .data_streams[] |
            .name + "\n" +
            (.indices | map("\t" + .index_name) | join("\n"))
        '
}

# Currently does not work for wildcard indices
# see https://stackoverflow.com/questions/45987172/delete-all-index-with-similary-name
delete_index() {
    local index_name=""
    echo >&2
    echo "Index deletion" >&2
    echo >&2

    # Prompt user for index name
    read -p "Enter index name: " index_name

    if [[ -z "$index_name" ]]; then
        echo "Index name is required!"
        exit 1
    fi

    echo "Deleting index: $index_name..." >&2

    curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X DELETE \
        "$ES_HOST/$index_name?pretty=true" \
        -H 'Content-Type: application/json'
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

    response=$(curl \
        -s \
        -u "$KIBANA_USERNAME:$KIBANA_PASSWORD" \
        -X GET \
        "$KIBANA_HOST/api/fleet/agents?perPage=100" \
        -H 'Content-Type: application/json' \
        -H 'kbn-xsrf: true')

    echo $response | jq -r '.list[] | .id + " " + .status'
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

main_menu() {
    local menu_options=(
        "cluster"
        "snapshots"
        "indices"
        "fleet"
        "EXIT"
    )

    while true; do
        echo
        echo "Please select an option:"

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
    local menu_options=("health" "state (verbose)" "nodes info (verbose)" "nodes_ids" "nodes settings (verbose)" "EXIT")

    while true; do
        echo
        echo "Please select an option:"

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

indices_menu() {
    local menu_options=(
        "show indices"
        "show indices with ILM errors"
        "show indices with ILM errors (verbose)"
        "show index ILM details"
        "show ILM policies"
        "show data streams"
        "show documents in index"
        "delete index"
        "delete data stream"
        "shards status"
        "EXIT"
    )

    while true; do
        echo
        echo "Please select an option:"

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                echo "Selected option: $option"
                case $option in
                    "show indices")
                        show_indices
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
                    "show ILM policies")
                        show_ilm_policies
                        ;;
                    "show data streams")
                        show_data_streams
                        ;;
                    "show documents in index")
                        show_documents_in_index
                        ;;
                    "delete index")
                        delete_index
                        ;;
                    "delete data stream")
                        delete_data_stream
                        ;;
                    "shards status")
                        shards_status_report
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
        echo "Please select an option:"

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
        "EXIT"
    )

    while true; do
        echo
        echo "Please select an option:"

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                echo "Selected option: $option"
                case $option in
                    "list agents")
                        # list_agents
                        list_agents_kibana_endpoint
                        ;;
                    "unenroll agents")
                        unenroll_agents
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

# TODO: Load credentials and other config from a file
main() {
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
       echo ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
       echo "Warning: You are running this script on a production environment!"
       echo ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
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

    main_menu

    # check_cluster_health
}

main "$@"