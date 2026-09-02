#!/usr/bin/env bats
load 'helpers'

# check-usb-sh — наполняется в соответствующем этапе (T2/T3/T4/T5)

@test "каркас: bats работает" {
    run true
    assert_success
}
