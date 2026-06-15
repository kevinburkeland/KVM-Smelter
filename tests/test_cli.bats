#!/usr/bin/env bats

setup() {
    export BATS_RUNNING="true"
    # Load common library
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
    
    # Set up transient environment for manifest loading
    export SMELTER_ROOT="${BATS_TEST_DIRNAME}/.."
}

@test "parse_smelter_args sets default variables correctly when ISO is provided" {
    unset DISTRO VERSION ISO_PATH OUTPUT_PATH PROFILE VCPU MEMORY DISK_SIZE
    
    # We must mock or provide an ISO since it's checked
    parse_smelter_args -i "/path/to/my.iso"
    
    [ "$DISTRO" = "azurelinux" ]
    [ "$VERSION" = "4.0" ]
    [ "$ISO_PATH" = "/path/to/my.iso" ]
    [ "$OUTPUT_PATH" = "./azurelinux-4.0-base.qcow2" ]
    [ "$PROFILE" = "base" ]
    [ "$VCPU" -eq 4 ]
    [ "$MEMORY" -eq 8192 ]
    [ "$DISK_SIZE" -eq 30 ]
}

@test "parse_smelter_args parses overrides correctly" {
    unset DISTRO VERSION ISO_PATH OUTPUT_PATH PROFILE VCPU MEMORY DISK_SIZE
    
    parse_smelter_args -d azurelinux -v 4.0 -i "/custom.iso" -o "/out.qcow2" -p base -c 8 -m 16384 -s 50
    
    [ "$DISTRO" = "azurelinux" ]
    [ "$VERSION" = "4.0" ]
    [ "$ISO_PATH" = "/custom.iso" ]
    [ "$OUTPUT_PATH" = "/out.qcow2" ]
    [ "$PROFILE" = "base" ]
    [ "$VCPU" -eq 8 ]
    [ "$MEMORY" -eq 16384 ]
    [ "$DISK_SIZE" -eq 50 ]
}

@test "parse_smelter_args rejects invalid CPUs, memory, or disk size" {
    run parse_smelter_args -i "x.iso" -c "invalid"
    [ "$status" -ne 0 ]
    
    run parse_smelter_args -i "x.iso" -m "-100"
    [ "$status" -ne 0 ]
    
    run parse_smelter_args -i "x.iso" -s "0"
    [ "$status" -ne 0 ]
}

@test "parse_smelter_args rejects unknown distro or profile" {
    run parse_smelter_args -i "x.iso" -d "unknown_distro"
    [ "$status" -ne 0 ]
    
    run parse_smelter_args -i "x.iso" -p "unknown_profile"
    [ "$status" -ne 0 ]
}

@test "parse_smelter_args errors in headless mode if ISO is missing" {
    # Non-interactive shell is assumed inside bats, but let's be sure
    run parse_smelter_args
    [ "$status" -ne 0 ]
    [[ "$output" == *"ISO path or URL must be specified"* ]]
}
