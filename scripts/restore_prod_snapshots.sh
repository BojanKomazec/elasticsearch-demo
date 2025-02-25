#!/bin/bash

# Directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"



# Function to get all SLM (Snapshot Lifecycle Management) policies dynamically
get_slm_policies() {
    curl -s -u "$USERNAME:$PASSWORD" -X GET "$ORIGIN_ES_HOST/_slm/policy?pretty" | jq -r 'keys[]'
}

# Function to list available snapshots for a specific policy
# list_snapshots_for_policy() {
#     local policy_name="$1"
#     curl -s -u "$USERNAME:$PASSWORD" -X GET "$TARGET_ES_HOST/_snapshot/$TARGET_ES_SNAPSHOT_REPOSITORY/_all" | jq -r \
#         --arg policy "$policy_name" \
#         '.snapshots[] | select(.snapshot | contains($policy)) | .snapshot' | sort -r
# }

get_latest_snapshot_for_policy() {
    local snapshot_repository="$1"
    local policy_name="$2"

    local response=$(curl \
        -s \
        -u "$USERNAME:$PASSWORD" \
        -X GET \
        "$TARGET_ES_HOST/_snapshot/$snapshot_repository/_all" \
        | jq -r \
            --arg policy "$policy_name" \
            '.snapshots | map(select(.metadata.policy == $policy)) | max_by(.start_time_in_millis) | .snapshot'
    )

    echo "$response"
}

# Function to trigger restoring a snapshot by name
# If necessary, consider adding the following parameters to the restore request:
#   \"rename_pattern\": \"(.+)\",
#   \"rename_replacement\": \"\1_restored\",
#   \"include_aliases\": false,
#
# ignore_unavailable: true - request ignores any index or data stream in indices that’s missing from the snapshot
# include_global_state: true - restores cluster-wide settings. These include index templates, ingest pipelines, and more. Index templates are required for restoring data streams.
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

restore_snapshot() {
    local snapshot_name="$1"
    local request_body="$2"

    echo && echo "Restoring snapshot: $snapshot_name..."

    curl \
        -u "$USERNAME:$PASSWORD" \
        -X POST \
        "$TARGET_ES_HOST/_snapshot/$TARGET_ES_SNAPSHOT_REPOSITORY/$snapshot_name/_restore?pretty" \
        -H "Content-Type: application/json" \
        -d "$request_body"

    echo && echo "Restore request sent."
}

# Function to monitor restore progress
# curl -u $USERNAME:$PASSWORD \
# -s \
# -X GET \
# $TARGET_ES_HOST \
# | jq -r \
# 'keys[] as $index | .[$index].shards | keys[] as $shard_arr_index | "\($index) \($shard_arr_index) \(.[$shard_arr_index].stage) \(.[$shard_arr_index].index.size.percent) \(.[$shard_arr_index].index.files.percent)"' | column -t
# to get the progress of the restore operation for each shard, like this:
# .internal.alerts-observability.metrics.alerts-default-000001                         0  DONE  100.0%  100.0%
# .internal.alerts-observability.metrics.alerts-default-000001                         1  DONE  0.0%    0.0%
check_restore_progress() {
    echo "Monitoring restore progress..."

    while true; do
        # Returned JSON is a list of indices where each index info contains the list of shards.
        # Each shard info object contains stage attribute. Its values can include:
        #   INIT - Recovery has not started.
        #   INDEX - Reading index metadata and copying bytes from source to destination.
        #   VERIFY_INDEX - Verifying the integrity of the index.
        #   TRANSLOG - Replaying transaction log.
        #   FINALIZE - Cleanup.
        #   DONE - Complete.
        progress=$(curl -s -u "$USERNAME:$PASSWORD" -X GET "$TARGET_ES_HOST/_recovery" | jq -r '[.[] | .shards[].stage] | unique | @csv')
        echo "Current restore stages: $progress"

        if [[ "$progress" == '"DONE"' ]]; then
            echo "Restore completed successfully!"
            break
        fi

        sleep 10
    done
}

check_cluster_health() {
    curl -s -u "$USERNAME:$PASSWORD" -X GET "$TARGET_ES_HOST/_cluster/health?pretty"
}

build_list_of_indices_to_exclude() {
    local excluded_indices=""

    # Redirecting to stderr (>&2) flushes output immediately
    echo >&2
    echo "Default indices to exclude: $DEFAULT_EXCLUDED_INDICES" >&2

    # Prompt user for indices to exclude e.g. -.transform-notifications-*,
    read -p "Enter a comma-separated list of additional indices to exclude from restoring snapshot (start each template/name with '-'; leave empty for none): " user_excluded_indices

    # Merge DEFAULT_EXCLUDED_INDICES and user_excluded_indices
    if [[ -n "$user_excluded_indices" ]]; then
        excluded_indices="$DEFAULT_EXCLUDED_INDICES,$user_excluded_indices"
    else
        excluded_indices="$DEFAULT_EXCLUDED_INDICES"
    fi

    echo "$excluded_indices"
}

build_list_of_features_to_include() {
    local features_to_restore=""

    echo "Default features to restore: $DEFAULT_FEATURES_TO_RESTORE" >&2

    # Prompt user for features to include e.g. transform,watcher
    read -p "Enter a comma-separated list of features to include when restoring snapshot (leave empty for none): " user_features_to_restore

    if [[ -n "$user_features_to_restore" ]]; then
        features_to_restore="$user_features_to_restore"
    else
        features_to_restore="$DEFAULT_FEATURES_TO_RESTORE"
    fi

    echo $features_to_restore
}

main() {
    # # Check if username and password were provided
    # if [ "$#" -ne 2 ]; then
    #     echo "Usage: $0 <username> <password>"
    #     exit 1
    # fi

    # USERNAME="$1"
    # PASSWORD="$2"

    # Check if environment is provided
    if [ "$#" -ne 1 ]; then
        echo "Usage: $0 <target_environment>"
        echo "target_environment: test, prod"
        exit 1
    fi

    # Assign the first argument to ENV variable
    ENV=$1
    # Look for .env file in the script's directory
    ENV_FILE="$SCRIPT_DIR/.env.restore.$ENV"

    # Check if the corresponding .env file exists
    if [ -f "$ENV_FILE" ]; then
        echo "Loading environment variables from $ENV_FILE..."
        source "$ENV_FILE"
    else
        echo "Error: Environment file $ENV_FILE not found!"
        exit 1
    fi

    echo "USERNAME=$USERNAME"
    # echo "PASSWORD=$PASSWORD"
    echo "ORIGIN_ES_HOST=$ORIGIN_ES_HOST"
    echo "TARGET_ES_HOST=$TARGET_ES_HOST"
    echo "TARGET_ES_SNAPSHOT_REPOSITORY=$TARGET_ES_SNAPSHOT_REPOSITORY"
    echo "DEFAULT_EXCLUDED_INDICES=$DEFAULT_EXCLUDED_INDICES"
    echo "DEFAULT_FEATURES_TO_RESTORE=$DEFAULT_FEATURES_TO_RESTORE"

    # Get policy names dynamically
    POLICIES=($(get_slm_policies))

    if [ ${#POLICIES[@]} -eq 0 ]; then
        echo "No snapshot policies found!"
        exit 1
    fi

    # User selects which policy to use
    echo
    echo "Select a policy to restore a snapshot from:"
    select policy in "${POLICIES[@]}"; do
        if [[ -n "$policy" ]]; then
            echo "Fetching latest snapshot for policy: $policy..."
            latest_snapshot=$(get_latest_snapshot_for_policy "$TARGET_ES_SNAPSHOT_REPOSITORY" "$policy")

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
                "$TARGET_ES_HOST/_snapshot/$TARGET_ES_SNAPSHOT_REPOSITORY/$latest_snapshot?pretty" \
                -H "Content-Type: application/json")

            echo $response | jq .

            echo
            echo "Snapshot indices (sorted by name):"
            echo
            echo $response | jq -r '.snapshots[0].indices[]' | sort

            EXCLUDED_INDICES=$(build_list_of_indices_to_exclude)
            echo
            echo "Indices to be excluded: $EXCLUDED_INDICES"

            FEATURES_TO_RESTORE=$(build_list_of_features_to_include)
            echo
            echo "Features to be restored: $FEATURES_TO_RESTORE"

            local request_body="
            {
                \"indices\": \"*,$EXCLUDED_INDICES\",
                \"ignore_unavailable\": true,
                \"include_global_state\": true,
                \"feature_states\": [\"$FEATURES_TO_RESTORE\"]
            }"
            echo
            echo "Request body: $request_body"

            echo
            read -p "Proceed with restore? (y/n): " confirm
            if [[ "$confirm" == "y" ]]; then
                restore_snapshot "$latest_snapshot" "$request_body"

                # Give some time for the restore operation to start so _recovery
                # can catch that some shards are in "INDEX" stage.
                sleep 10

                check_restore_progress

                check_cluster_health

                # ToDo: Add checking if number of documents in index from the snapshot
                # is the same in origin and target cluster
            else
                echo "Restore cancelled."
            fi

            break
        else
            echo "Invalid selection. Please choose a valid policy."
        fi
    done
}

main "$@"
