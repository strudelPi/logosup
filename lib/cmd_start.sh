#!/usr/bin/env bash
# DESCRIPTION: Start the Logos Blockchain node

cmd_start() {
    detect_platform
    check_docker

    local config_path
    config_path="$(get_user_config_path)"
    local compose_path
    compose_path="$(get_compose_path)"

    if [[ ! -f "$config_path" ]]; then
        die "Node configuration not found at $config_path\nRun 'logosup install' first."
    fi

    if [[ ! -f "$compose_path" ]]; then
        die "Docker compose file not found. Run 'logosup install' first."
    fi

    if docker_is_running; then
        log_warn "Logos Node is already running"
        log_info "Use 'logosup status' to check node status"
        log_info "Use 'logosup stop' to stop, then 'logosup start' to restart"
        return 0
    fi

    # Regenerate compose if port settings changed
    if [[ -f "$compose_path" ]]; then
        if ! grep -q "\"${LOGOS_API_PORT}:8080\"" "$compose_path" 2>/dev/null || \
           ! grep -q "\"${LOGOS_UDP_PORT}:3000/udp\"" "$compose_path" 2>/dev/null; then
            log_info "Port settings changed — regenerating docker-compose.yml"
            generate_compose_file
        fi
    fi

    log_step "Starting Logos Node..."
    local start_output
    if ! start_output="$(docker_up 2>&1)"; then
        echo "$start_output"
        if echo "$start_output" | grep -q "port is already allocated"; then
            local conflict_port
            conflict_port="$(echo "$start_output" | grep -oE 'Bind for [0-9.:]+' | head -1 | sed 's/Bind for //' | sed 's/.*://')" || true
            echo ""
            log_error "Port ${conflict_port:-} is already in use by another process."
            log_info "Find what's using it:  ${BOLD}sudo lsof -i :${conflict_port:-${LOGOS_API_PORT}} | grep LISTEN${RESET}"
            log_info "Or change the port:    ${BOLD}Edit LOGOS_API_PORT in $LOGOS_SETTINGS_FILE${RESET}"
            log_info "Then regenerate:       ${BOLD}logosup update node${RESET}"
        else
            log_error "Failed to start node. Check 'logosup logs' for details."
        fi
        return 1
    fi

    log_success "Logos Node container started"

    # #region agent log — debug session 989b70
    _DBG_LOG="/home/strudelpi/git/github/logos/logosup/.cursor/debug-989b70.log"
    _dbg() { printf '{"sessionId":"989b70","timestamp":%s,"location":"cmd_start.sh:%s","hypothesisId":"%s","message":"%s","data":%s}\n' \
        "$(date +%s%3N)" "$1" "$2" "$3" "$4" >> "$_DBG_LOG" 2>/dev/null || true; }

    # H2: kernel ip_forward (independent of UFW policy)
    _ip_fwd="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
    _dbg "$LINENO" "H2" "kernel ip_forward" "{\"ip_forward\":\"${_ip_fwd}\"}"

    # H3/H4: MTU of bridge vs host physical interface
    _net_id="$(docker network inspect logosnode-net --format '{{slice .Id 0 12}}' 2>/dev/null || echo "")"
    _br_mtu="$(ip link show "br-${_net_id}" 2>/dev/null | grep -oP 'mtu \K\d+' || echo "unknown")"
    _eth_iface="$(ip route get 65.109.51.37 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || echo "unknown")"
    _eth_mtu="$(ip link show "${_eth_iface}" 2>/dev/null | grep -oP 'mtu \K\d+' || echo "unknown")"
    _dbg "$LINENO" "H3_H4" "MTU bridge vs host interface" "{\"bridge_mtu\":\"${_br_mtu}\",\"host_iface\":\"${_eth_iface}\",\"host_mtu\":\"${_eth_mtu}\"}"

    # H1: TCP probe to bootstrap servers (tests if host is up; TCP will be refused but reachable beats timeout)
    for _port in 3000 3001 3002 3003; do
        _tcp="$(timeout 4 bash -c "echo >/dev/tcp/65.109.51.37/${_port}" 2>&1 && echo "connected" || echo "refused_or_timeout")"
        _dbg "$LINENO" "H1" "TCP probe bootstrap 65.109.51.37:${_port}" "{\"port\":${_port},\"result\":\"${_tcp}\"}"
    done

    # H5: outbound UDP reachability from container (HTTPS proves TCP NAT works; test UDP separately)
    _udp_ext="$(docker exec "$LOGOS_CONTAINER_NAME" timeout 5 sh -c 'echo hi | nc -u -w3 1.1.1.1 443 2>&1 && echo ok' 2>/dev/null || echo "nc_unavailable")"
    _dbg "$LINENO" "H5" "container UDP NAT reachability test" "{\"result\":\"${_udp_ext}\"}"

    # H4: Docker port bindings (check if 3000/udp inbound mapping exists)
    _port_bindings="$(docker inspect "$LOGOS_CONTAINER_NAME" --format '{{json .HostConfig.PortBindings}}' 2>/dev/null || echo "{}")"
    _dbg "$LINENO" "H4" "Docker port bindings" "{\"port_bindings\":${_port_bindings}}"

    # Container external IP (what IP does the container appear to have externally)
    _ext_ip="$(docker exec "$LOGOS_CONTAINER_NAME" timeout 5 curl -sf https://api.ipify.org 2>/dev/null || echo "failed")"
    _dbg "$LINENO" "H3" "container external IP" "{\"external_ip\":\"${_ext_ip}\"}"

    # Node listen addresses from API (after a brief settle)
    sleep 2
    _net_info="$(curl -sf "http://localhost:${LOGOS_API_PORT}/network/info" 2>/dev/null || echo "null")"
    _dbg "$LINENO" "H3" "node network/info" "${_net_info:-null}"
    # #endregion agent log

    log_info "Waiting for node to initialize..."

    local health_rc
    docker_health_wait 120 && health_rc=0 || health_rc=$?

    if [[ $health_rc -eq 0 ]]; then
        echo ""
        log_success "Node is running and healthy!"
        echo ""
        _show_brief_status
    elif [[ $health_rc -eq 2 ]]; then
        echo ""
        log_error "Node container exited unexpectedly"
        log_info "Last log lines:"
        echo ""
        $DOCKER_CMD logs --tail 30 "$LOGOS_CONTAINER_NAME" 2>&1 | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${RESET}"
        done || true
        echo ""
        log_info "For the full log run: ${BOLD}logosup logs${RESET}"
        return 1
    else
        echo ""
        log_warn "Node started but health check hasn't passed yet"
        log_info "This is normal during initial sync. The node may take a few minutes."
        log_info "Check progress with: ${BOLD}logosup status${RESET}"
        log_info "View logs with:      ${BOLD}logosup logs${RESET}"
    fi

    # Start monitoring if compose file exists
    local monitoring_compose
    monitoring_compose="$LOGOS_NODE_DIR/docker-compose.monitoring.yml"
    if [[ -f "$monitoring_compose" ]]; then
        source "$LOGOS_NODE_LIB/monitoring.sh"
        if ! monitoring_is_running; then
            log_step "Starting monitoring stack..."
            monitoring_up
            local grafana_host
            grafana_host="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
            grafana_host="${grafana_host:-localhost}"
            log_success "Monitoring running at ${BOLD}https://${grafana_host}:${LOGOS_GRAFANA_PORT}${RESET}"
        fi
    fi

    echo ""
    log_info "Check node status: ${BOLD}logosup status${RESET}"
}

_show_brief_status() {
    local api_url="http://localhost:${LOGOS_API_PORT}"

    local consensus
    consensus="$(curl -sf "${api_url}/cryptarchia/info" 2>/dev/null)" || true

    local network
    network="$(curl -sf "${api_url}/network/info" 2>/dev/null)" || true

    if [[ -n "$consensus" ]]; then
        local mode slot height
        mode="$(echo "$consensus" | sed -E 's/.*"mode":"([^"]+)".*/\1/')"
        slot="$(echo "$consensus" | sed -E 's/.*"slot":([0-9]+).*/\1/')"
        height="$(echo "$consensus" | sed -E 's/.*"height":([0-9]+).*/\1/')"

        log_info "Consensus mode: ${BOLD}${mode}${RESET}"
        log_info "Slot: ${slot}  |  Height: ${height}"
    fi

    if [[ -n "$network" ]]; then
        local peers
        peers="$(echo "$network" | sed -E 's/.*"n_peers":([0-9]+).*/\1/')"
        log_info "Connected peers: ${BOLD}${peers}${RESET}"
    fi
}
