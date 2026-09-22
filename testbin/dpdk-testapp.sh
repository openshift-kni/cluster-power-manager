#!/usr/bin/env bash

set -o errexit
set -o pipefail

KUBE_CLI="${KUBE_CLI:-kubectl}"
if [[ "$KUBE_CLI" != "kubectl" && "$KUBE_CLI" != "oc" ]]; then
    echo "ERROR: KUBE_CLI must be set to kubectl or oc" >&2
    exit 1
fi
if ! command -v "$KUBE_CLI" >/dev/null 2>&1; then
    echo "ERROR: CLI executable '$KUBE_CLI' was not found in PATH" >&2
    exit 1
fi

# When enabled, pin server and client to non-sibling CPUs.
# When disabled (default), use all CPUs listed in the PowerNode CR (e.g., HT disabled scenarios).
NON_SIBLINGS=false
REPLICAS=1

# build_lcore_map converts a space-separated CPU list into the DPDK --lcores format (cpu@cpu,...).
# If NON_SIBLINGS is true, only the first half of the CPUs are used.
function build_lcore_map {
    local cpu_list="$1"
    if $NON_SIBLINGS; then
        local count
        count=$(echo "$cpu_list" | wc -w | awk '{print $1}')
        local half=$(( count > 1 ? count/2 : count ))
        cpu_list=$(echo "$cpu_list" | tr ' ' '\n' | head -n "$half" | tr '\n' ' ')
    fi
    local result=""
    for cpu in $cpu_list; do
        if [ -n "$result" ]; then result+=","; fi
        result+="${cpu}@${cpu}"
    done
    echo "$result"
}

# expand_cpu_ranges expands a comma-separated CPU string that may contain
# ranges (e.g. "0-3,12,15-17") into a space-separated list of individual
# CPU IDs (e.g. "0 1 2 3 12 15 16 17").
function expand_cpu_ranges {
    local input="$1"
    local result=""
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            local start=${part%-*}
            local end=${part#*-}
            for ((i=start; i<=end; i++)); do
                result+="$i "
            done
        else
            result+="$part "
        fi
    done
    echo "$result"
}

# wait_for_container_cpus waits until the PowerNodeState has exclusive CPUs for a container
# and returns the space-separated CPU list.
function wait_for_container_cpus {
    local node="$1"
    local pod_name="$2"
    local container_name="$3"
    local cpus=""
    local attempts=0
    local max_attempts=150  # 5 minutes (150 * 2s)
    while true; do
        if (( attempts++ >= max_attempts )); then
            echo "ERROR: Timed out waiting for CPUs for $container_name in $pod_name" >&2
            exit 1
        fi
        local raw
        raw=$("$KUBE_CLI" get powernodestate "${node}-power-state" -n power-manager -o \
            jsonpath="{range .status.cpuPools.exclusive[?(@.pod==\"${pod_name}\")]}{range .powerContainers[?(@.name==\"${container_name}\")]}{.cpuIDs}{end}{end}" 2>/dev/null)
        if [ -n "$raw" ]; then
            cpus=$(expand_cpu_ranges "$(echo "$raw" | tr -d '[] ')")
        fi
        if [ -n "$cpus" ]; then break; fi
        echo "PowerNodeState not yet updated ($container_name for $pod_name). Retrying..." >&2
        sleep 2
    done
    echo "$cpus"
}

# wait_for_testpmd_prompt waits until the tmux pane shows the interactive prompt.
function wait_for_testpmd_prompt {
    local pod="$1"
    local container="$2"
    local session="$3"
    local attempts=0
    local max_attempts=30
    while true; do
        local pane
        pane=$("$KUBE_CLI" exec -n power-manager "$pod" -c "$container" -- tmux capture-pane -pt "$session" 2>&1) || true
        if grep -q 'testpmd>' <<<"$pane"; then
            return 0
        fi
        if (( attempts++ >= max_attempts )); then
            echo "ERROR: $session testpmd did not reach the prompt in $pod/$container" >&2
            echo "  --- tmux $session ($pod/$container) ---" >&2
            echo "$pane" >&2
            return 1
        fi
        sleep 1
    done
}

# setup_dpdk_for_pod starts the DPDK server and client processes on a single pod.
function setup_dpdk_for_pod {
    local pod="$1"
    local node="$2"
    echo "--- Setting up DPDK on pod $pod (node: $node) ---"

    local server_list
    server_list=$(wait_for_container_cpus "$node" "$pod" "server")
    local server_cpus
    server_cpus=$(build_lcore_map "$server_list")
    local server_cpus_num=$(($(echo "$server_cpus" | grep -o '@' | wc -l) - 1))

    local client_list
    client_list=$(wait_for_container_cpus "$node" "$pod" "client")
    local client_cpus
    client_cpus=$(build_lcore_map "$client_list")
    local client_cpus_num=$(($(echo "$client_cpus" | grep -o '@' | wc -l) - 1))

    # Unique per replica: DPDK memif uses abstract sockets in the netns, and
    # hostNetwork pods share the host netns (emptyDir does not isolate them).
    local memif_sock="/var/run/memif/memif-$(echo "$pod" | cksum | awk '{print $1}').sock"

    echo "  Starting server (CPUs: $server_cpus)..."
    # exec bash keeps the session if testpmd exits so the pane still shows the EAL error.
    local server_cmd="dpdk-testpmd --no-pci --lcores $server_cpus --file-prefix=rte \
        --huge-dir=/hugepages-1Gi \
        --vdev=net_memif0,role=server,socket=${memif_sock} -- \
        --rxq=$server_cpus_num --txq=$server_cpus_num --nb-cores=$server_cpus_num \
        --interactive --rss-udp --forward-mode=csum --record-core-cycles --record-burst-stats; exec bash"
    "$KUBE_CLI" exec -n power-manager "$pod" -c server -- tmux new-session -d -s server "$server_cmd"
    wait_for_testpmd_prompt "$pod" server server

    echo "  Starting client (CPUs: $client_cpus)..."
    local client_cmd="dpdk-testpmd --no-pci --lcores $client_cpus --file-prefix=client \
        --huge-dir=/hugepages-1Gi \
        --vdev=net_memif0,role=client,socket=${memif_sock} -- \
        --rxq=$server_cpus_num --txq=$server_cpus_num --nb-cores=$client_cpus_num \
        --interactive --rss-udp --forward-mode=txonly; exec bash"
    "$KUBE_CLI" exec -n power-manager "$pod" -c client -- tmux new-session -d -s client "$client_cmd"
    wait_for_testpmd_prompt "$pod" client client

    # Push heavier traffic from the client
    "$KUBE_CLI" exec -n power-manager "$pod" -c client -- tmux send-keys -t client "set burst 512" C-m
    # Start packet generation from client
    "$KUBE_CLI" exec -n power-manager "$pod" -c client -- tmux send-keys -t client "start" C-m
    # Start packet processing from server
    "$KUBE_CLI" exec -n power-manager "$pod" -c server -- tmux send-keys -t server "start" C-m
    echo "  Pod $pod deployed successfully"
}

function setup_dpdk_testapp {
    "$KUBE_CLI" apply -f examples/example-dpdk-testapp.yaml

    if [ "$REPLICAS" -ne 1 ]; then
        "$KUBE_CLI" scale -n power-manager deployment/dpdk-testapp --replicas="$REPLICAS"
    fi

    # Wait until all replicas are ready.
    "$KUBE_CLI" wait -n power-manager \
        --for=jsonpath='{.status.readyReplicas}'="$REPLICAS" \
        --timeout=180s deployment/dpdk-testapp

    # Wait for all pods to be running.
    PODS=$("$KUBE_CLI" get pods -n power-manager -l app=dpdk-testapp \
        -ojsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    for POD in $PODS; do
        "$KUBE_CLI" wait --for=jsonpath='{.status.phase}'=Running pod/"$POD" -n power-manager --timeout=120s
    done

    # Start DPDK processes on each pod.
    for POD in $PODS; do
        NODE=$("$KUBE_CLI" get pod "$POD" -n power-manager -ojsonpath='{.spec.nodeName}')
        setup_dpdk_for_pod "$POD" "$NODE"
    done

    echo "All $REPLICAS pod(s) deployed successfully"
}

function delete_dpdk_testapp {
    "$KUBE_CLI" delete -f examples/example-dpdk-testapp.yaml --ignore-not-found=true

    # Wait for the deployment to be deleted if it exists
    "$KUBE_CLI" wait -n power-manager --for=delete deployment/dpdk-testapp --timeout=120s || true

    echo "Waiting for dpdk-testapp pods to terminate..."
    for i in {1..60}; do
        if [ -z "$("$KUBE_CLI" get pods -n power-manager -l app=dpdk-testapp --no-headers 2>/dev/null | awk 'NF>0{print}' | head -n1)" ]; then
            echo "All dpdk-testapp pods terminated."
            break
        fi
        sleep 2
    done
}

: "${KUBECONFIG:=$HOME/.kube/config}"

# Usage: dpdk-testapp.sh [-d] [--non-siblings] [--replicas N]
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            delete_dpdk_testapp
            exit 0
            ;;
        --non-siblings)
            NON_SIBLINGS=true
            shift
            ;;
        --replicas)
            REPLICAS="${2:?--replicas requires a number}"
            if ! [[ "$REPLICAS" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --replicas must be a positive integer" >&2
                exit 1
            fi
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: dpdk-testapp.sh [-d] [--non-siblings] [--replicas N]"
            exit 1
            ;;
    esac
done

setup_dpdk_testapp
exit 0
