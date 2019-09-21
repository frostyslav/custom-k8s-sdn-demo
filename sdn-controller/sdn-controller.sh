#!/bin/bash

BRIDGE_NAME=
BRIDGE_ADDRESS=

log() {
    echo "$(date): $1"
}

parse_params() {
    if [ -z "$BRIDGE_NAME" ]; then
        BRIDGE_NAME=bridge0
    fi
    if [ -z "$BRIDGE_ADDRESS" ]; then
        BRIDGE_ADDRESS=192.168.5.1/24
    fi
}

create_bridge() {
    if ! ip -o link show $BRIDGE_NAME > /dev/null 2>&1; then
        ip link add dev $BRIDGE_NAME type bridge
        ip addr add $BRIDGE_ADDRESS dev $BRIDGE_NAME
        ip link set dev $BRIDGE_NAME up
    fi
}

gen_mac() {
    # mac OUI
    oui='00:00:00'

    # nic specific id
    hexchars="0123456789ABCDEF"
    nic=$( i=0; while [ $i -lt 6 ]; do i=$((i + 1)); echo -n ${hexchars:$(( RANDOM % 16 )):1}; done | sed -e 's/\(..\)/:\1/g' )

    echo "${oui}${nic}"
}

cdr2mask() {
   # Number of args to shift, 255..255, first non-255 byte, zeroes
   set -- $(( 5 - ($1 / 8) )) 255 255 255 255 $(( (255 << (8 - ($1 % 8))) & 255 )) 0 0 0
   [ $1 -gt 1 ] && shift $1 || shift
   echo ${1-0}.${2-0}.${3-0}.${4-0}
}

network_address_to_ips() {
    # define empty array to hold the ip addresses
    ips=()
    # create array containing network address and subnet
    network=(${1//\// })
    # split network address by dot
    iparr=(${network[0]//./ })
    # check for subnet mask or create subnet mask from CIDR notation
    if [[ ${network[1]} =~ '.' ]]; then
        netmaskarr=(${network[1]//./ })
    else
        if [[ $((8-${network[1]})) -gt 0 ]]; then
            netmaskarr=($((256-2**(8-${network[1]}))) 0 0 0)
        elif  [[ $((16-${network[1]})) -gt 0 ]]; then
            netmaskarr=(255 $((256-2**(16-${network[1]}))) 0 0)
        elif  [[ $((24-${network[1]})) -gt 0 ]]; then
            netmaskarr=(255 255 $((256-2**(24-${network[1]}))) 0)
        elif [[ $((32-${network[1]})) -gt 0 ]]; then 
            netmaskarr=(255 255 255 $((256-2**(32-${network[1]}))))
        fi
    fi
    # correct wrong subnet masks (e.g. 240.192.255.0 to 255.255.255.0)
    [[ ${netmaskarr[2]} == 255 ]] && netmaskarr[1]=255
    [[ ${netmaskarr[1]} == 255 ]] && netmaskarr[0]=255
    # generate list of ip addresses
    for i in $(seq 0 $((255-${netmaskarr[0]}))); do
        for j in $(seq 0 $((255-${netmaskarr[1]}))); do
            for k in $(seq 0 $((255-${netmaskarr[2]}))); do
                for l in $(seq 1 $((255-${netmaskarr[3]}))); do
                    ips+=( $(( $i+$(( ${iparr[0]}  & ${netmaskarr[0]})) ))"."$(( $j+$(( ${iparr[1]} & ${netmaskarr[1]})) ))"."$(($k+$(( ${iparr[2]} & ${netmaskarr[2]})) ))"."$(($l+$((${iparr[3]} & ${netmaskarr[3]})) )) )
                done
            done
        done
    done
}

next_available_ip() {
    used_addresses=$(curl -s 127.0.0.1:8080/api/v1/pods | jq -r .items[].metadata.annotations.network | jq -r .ip | sort -V | uniq)
    network_address_to_ips $BRIDGE_ADDRESS
    bridge_ip=$(echo $BRIDGE_ADDRESS | awk -F/ '{print $1}')
    AVAILABLE_IP=
    while read -r ip; do
        ip_is_used=false
        if [ $ip = $bridge_ip ]; then
            continue
        fi
        while read -r used_ip; do
            if [ $ip = $used_ip ]; then
                ip_is_used=true
                break
            fi
        done < <(printf '%s\n' "$used_addresses")
        if [ $ip_is_used = false ]; then
            AVAILABLE_IP=$ip
            break
        fi
    done < <(echo ${ips[@]} | tr ' ' '\n')
    echo $AVAILABLE_IP
}

watch() {
    while read -r line; do
        nodeName=$(echo $line | jq -M -r .object.spec.nodeName)

        if [ $nodeName != $(hostname) ]; then
            log "Skip event from external node: $nodeName"
            continue
        fi

        eventType=$(echo $line | jq -M -r .type)
        podName=$(echo $line | jq -M -r .object.metadata.name)
        podNamespace=$(echo $line | jq -M -r .object.metadata.namespace)

        log "Handling event with type: $eventType, pod name: $podName, pod namespace: $podNamespace"
        hostNetwork=$(echo $line | jq -M -r .object.spec.hostNetwork)

        if [ "$hostNetwork" = "true" ]; then
            log "Skip event $eventType from pod with host network: $podNamespace/$podName"
            continue
        fi

        if [ "$eventType" = "ADDED" ] || [ "$eventType" = "MODIFIED" ]; then
            MAC=$(gen_mac)
            IFNAME=eth0
            IP=$(next_available_ip)
            MASK=$(cdr2mask $(echo $BRIDGE_ADDRESS | awk -F/ '{print $2}'))
            GW=$(echo $BRIDGE_ADDRESS | awk -F/ '{print $1}')

            annotations=$(echo $line | jq -M -r .object.metadata.annotations.network)
            if [ -z $annotations ] || [ $annotations = "null" ]; then
                data=$(jq -c -M -n --arg mac "$MAC" --arg ip "$IP" --arg mask "$MASK" --arg gw "$GW" --arg ifname "$IFNAME" --arg brname "$BRIDGE_NAME" '{"mac":$mac,"ip":$ip,"mask":$mask,"gateway":$gw,"interface_name":$ifname,"bridge_name":$brname}' | sed 's%"%\\\"%g')
                log "Configure pod $podNamespace/$podName with $data"
                patch="[{\"op\":\"add\",\"path\":\"/metadata/annotations\",\"value\": {\"network\":\"$data\"}}]"
                curl -s --header "Content-Type: application/json-patch+json" --data "$patch" -X PATCH http://127.0.0.1:8080/api/v1/namespaces/$podNamespace/pods/$podName
            fi
        fi

    done < <(curl -s 127.0.0.1:8080/api/v1/namespaces/kube-system/pods?watch=true)
}

parse_params
create_bridge
watch


# echo 1 > /proc/sys/net/ipv4/ip_forward
# iptables -A FORWARD -i bridge0 -o eth0 -j ACCEPT
# iptables -A FORWARD -i eth0 -o bridge0 -m state --state ESTABLISHED,RELATED -j ACCEPT
# iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
