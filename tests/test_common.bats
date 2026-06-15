#!/usr/bin/env bats

setup() {
    export BATS_RUNNING="true"
    # Load common library
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
}

@test "log_info outputs correctly formatted message" {
    run log_info "Test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"*"Test message"* ]]
}

@test "log_err outputs correctly formatted message to stderr" {
    run log_err "Error message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ERROR]"*"Error message"* ]]
}

@test "resolve_supported_os_variant bypasses check when BATS_RUNNING is set" {
    export BATS_RUNNING="true"
    run resolve_supported_os_variant "fedora40"
    [ "$status" -eq 0 ]
    [ "$output" = "fedora40" ]
}

@test "resolve_supported_os_variant falls back correctly when BATS_RUNNING is unset" {
    local saved_bats="${BATS_RUNNING:-}"
    unset BATS_RUNNING
    
    # Mock virt-install inside this subshell
    virt-install() {
        if [[ "$*" == *"--osinfo name=fedora40"* ]]; then
            return 1
        elif [[ "$*" == *"--osinfo name=fedora38"* ]]; then
            return 0
        elif [[ "$*" == *"--osinfo list"* ]]; then
            echo "fedora38"
            echo "fedora37"
            return 0
        else
            return 1
        fi
    }
    export -f virt-install
    
    run resolve_supported_os_variant "fedora40"
    
    # Restore original state
    if [ -n "$saved_bats" ]; then
        export BATS_RUNNING="$saved_bats"
    fi
    unset -f virt-install
    
    [ "$status" -eq 0 ]
    [ "$output" = "fedora38" ]
}

@test "validate_smelter_env_file accepts valid settings and rejects malicious inputs" {
    local env_file
    env_file=$(mktemp)
    
    # 1. Test a valid configuration
    cat << 'EOF' > "$env_file"
# This is a comment
SMELTER_DEFAULT_USER="azureuser"
SMELTER_TIMEZONE="America/Los_Angeles"
SMELTER_SSH_KEY_PATH="/root/.ssh/id_ed25519.pub"
EOF
    run validate_smelter_env_file "$env_file"
    [ "$status" -eq 0 ]
    
    # 2. Test invalid lines (no namespace)
    cat << 'EOF' > "$env_file"
INVALID_VAR="value"
EOF
    run validate_smelter_env_file "$env_file"
    [ "$status" -ne 0 ]

    # 3. Test invalid lines (unquoted)
    cat << 'EOF' > "$env_file"
SMELTER_DEFAULT_USER=azureuser
EOF
    run validate_smelter_env_file "$env_file"
    [ "$status" -ne 0 ]

    # 4. Test command injection (backticks)
    cat << 'EOF' > "$env_file"
SMELTER_DEFAULT_USER="`whoami`"
EOF
    run validate_smelter_env_file "$env_file"
    [ "$status" -ne 0 ]

    # 5. Test command injection (dollar sign / subshell)
    cat << 'EOF' > "$env_file"
SMELTER_DEFAULT_USER="$(whoami)"
EOF
    run validate_smelter_env_file "$env_file"
    [ "$status" -ne 0 ]

    # 6. Test command injection (quote breakout / semicolon)
    cat << 'EOF' > "$env_file"
SMELTER_DEFAULT_USER="azureuser\"; id; echo \""
EOF
    run validate_smelter_env_file "$env_file"
    [ "$status" -ne 0 ]
    
    rm -f "$env_file"
}
