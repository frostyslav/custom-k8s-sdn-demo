#!/usr/bin/env bash

SPEC_VERSION=0.4.0

K8S_POD_NAME=
K8S_POD_NAMESPACE=
K8S_POD_INFRA_CONTAINER_ID=
NETNS=
LOG_FILE=/var/log/cni.log

exit_and_log() {
    code=$1
    short_message=$2
    long_message=$3
    echo "$long_message" >> $LOG_FILE

    jq -M -n --arg version "$SPEC_VERSION" --arg code "$code" --arg msg "$short_message" --arg details "$long_message" \
    '{
        "cniVersion": $version,
        "code": $code | tonumber,
        "msg": $msg,
        "details": $details
    }'

    exit $code
}

parse_params() {
    if [ -z "$CNI_COMMAND" ]; then
        exit_and_log 100 "arg value is missing" "CNI_COMMAND is not provided"
    fi

    if [ ! "$CNI_COMMAND" = "ADD" ] && [ ! "$CNI_COMMAND" = "DEL" ] && [ ! "$CNI_COMMAND" = "CHECK" ] && [ ! "$CNI_COMMAND" = "VERSION" ]; then
        exit_and_log 100 "arg value is wrong" "CNI_COMMAND is not one of 'ADD', 'DEL', 'CHECK' or 'VERSION'"
        exit 1
    fi

    # if [ -z "$CNI_CONTAINERID" ]; then
    #     echo "CNI_CONTAINERID is not provided"
    # fi

    if [ -z "$CNI_NETNS" ]; then
        if [ "$CNI_COMMAND" = "ADD" ]; then
            exit_and_log 100 "arg value is missing" "CNI_NETNS is not provided"
        fi
    else
        NETNS=$(parse_netns "$CNI_NETNS")
    fi

    # if [ -z "$CNI_IFNAME" ]; then
    #     if [ "$CNI_COMMAND" = "ADD" ] || [ "$CNI_COMMAND" = "DEL" ]; then
    #         echo "CNI_IFNAME is not provided"
    #         exit 1
    #     fi
    # fi

    if [ -z "$CNI_ARGS" ]; then
        if [ "$CNI_COMMAND" = "ADD" ] || [ "$CNI_COMMAND" = "DEL" ]; then
            exit_and_log 100 "arg value is missing" "CNI_ARGS is not provided"
        fi
    else
        parse_args "$CNI_ARGS"
        if [ -z "$K8S_POD_NAME" ] || [ -z "$K8S_POD_NAMESPACE" ] || [ -z "$K8S_POD_INFRA_CONTAINER_ID" ]; then
            exit_and_log 100 "arg value is missing" "CNI_ARGS are missing required values"
        fi
    fi

    # if [ -z "$CNI_PATH" ]; then
    #     if [ "$CNI_COMMAND" = "ADD" ] || [ "$CNI_COMMAND" = "ADD" ]; then
    #         echo "CNI_PATH is not provided"
    #         exit 1
    #     fi
    # fi
}

# trimming and splitting functions
mfcb() { local val="$4"; "$1"; eval "$2[$3]=\$val;"; };
val_ltrim() { if [[ "$val" =~ ^[[:space:]]+ ]]; then val="${val:${#BASH_REMATCH[0]}}"; fi; };
val_rtrim() { if [[ "$val" =~ [[:space:]]+$ ]]; then val="${val:0:${#val}-${#BASH_REMATCH[0]}}"; fi; };
val_trim() { val_ltrim; val_rtrim; };

parse_netns() {
    string=$1

    echo "$string" | awk -F/ '{print $3}'
}

parse_args() {
    ARGS=$1

    # split args
    readarray -c1 -C 'mfcb val_trim elements' -td\; <<<"$ARGS;"; unset 'elements[-1]'

    # parse args elements
    for el in "${elements[@]}"
    do
        key=$(echo "$el" | awk -F= '{print $1;}')
        val=$(echo "$el" | awk -F= '{print $2;}')
        if [ "$key" = "K8S_POD_NAME" ] && [ ! -z "$val" ]; then
            K8S_POD_NAME=$val
        fi 
        if [ "$key" = "K8S_POD_NAMESPACE" ] && [ ! -z "$val" ]; then
            K8S_POD_NAMESPACE=$val
        fi
        if [ "$key" = "K8S_POD_INFRA_CONTAINER_ID" ] && [ ! -z "$val" ]; then
            K8S_POD_INFRA_CONTAINER_ID=$val
        fi
    done
}

version() {
    jq -M -n --arg version "$SPEC_VERSION" \
        '{
            "cniVersion": $version,
            "supportedVersions": [
                "0.1.0",
                "0.2.0",
                "0.3.0",
                "0.3.1",
                $version
            ]
        }'
    exit 0
}

get_config() {
    network_data=$(curl 127.0.0.1:8080/api/v1/namespaces/$K8S_POD_NAMESPACE/pods/$K8S_POD_NAME | jq -r .metadata.annotations.network)
}

mask2cdr() {
   # Assumes there's no "255." after a non-255 byte in the mask
   local x=${1##*255.}
   set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
   x=${1%%$3*}
   echo $(( $2 + (${#x}/4) ))
}

parse_params

if [ "$CNI_COMMAND" = "VERSION" ]; then
    version
fi

if [ "$CNI_COMMAND" = "ADD" ]; then
    get_config

    bridge_name=$(jq -rn --argjson data $network_data '$data.bridge')
    mac=$(jq -rn --argjson data $network_data '$data.mac')
    ip=$(jq -rn --argjson data $network_data '$data.ip')
    mask=$(jq -rn --argjson data $network_data '$data.mask')
    cidr=$(mask2cdr $mask)
    gw=$(jq -rn --argjson data $network_data '$data.gateway')
    ifname=$(jq -rn --argjson data $network_data '$data.ifname')


    veth_external=$(echo "$K8S_POD_INFRA_CONTAINER_ID" | cut -c 1-15)
    veth_internal=$(echo $(echo "$K8S_POD_INFRA_CONTAINER_ID" | cut -c 1-13)_c)
    if ! ip -o link | grep -q "$veth_external"; then
        ip link add dev "$veth_external" type veth peer name "$veth_internal"
        ip link set dev "$veth_external" up
        ip link set dev "$veth_external" master $bridge_name
        ip link set "$veth_internal" netns "$NETNS"
        ip netns exec "$NETNS" ip link set dev "$veth_internal" name "$ifname"
        ip netns exec "$NETNS" ip link set dev "$ifname" up
    fi

    ip netns exec "$NETNS" ip link set dev "$ifname" address "$mac"
    ip netns exec "$NETNS" ip a add "$ip/$cidr" dev "$ifname"
    ip netns exec "$NETNS" ip route add default via "$gw" dev "$ifname"

    jq -M -n --arg version "$SPEC_VERSION" --arg ifname "$CNI_IFNAME" --arg mac "$MAC" --arg address "$ip/$cidr" --arg address gw "$gw" --arg netns "$CNI_NETNS" \
        '{
            "cniVersion": $version,
            "interfaces": [
                {
                    "name": $ifname,
                    "mac": $mac,
                    "sandbox": $netns
                }
            ],
            "ips": [
                {
                    "version": "4",
                    "address": $address,
                    "gateway": $gw,
                    "interface": 0
                }
            ],
        }'
fi

if [ "$CNI_COMMAND" = "DEL" ]; then
    exit 0
fi

if [ "$CNI_COMMAND" = "CHECK" ]; then
    echo "NOT IMPLEMENTED"
    exit 0
fi
