#!/bin/sh

TEST_DIR="/tmp/pac_policy_tests"
JOURNAL_TOOL="$(pwd)/journal/journal_tool"
POLICY_ENGINE="$(pwd)/policy/policy_engine.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

setup() {
    echo "Setting up test environment..."
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/tier2-root" "$TEST_DIR/tier3-root"
    
    cat > "$TEST_DIR/health_healthy.json" <<EOF
{
  "overall_score": 5,
  "overall_status": "healthy",
  "legacy_format": {
    "wdt_ok": 0,
    "ecc_ok": 1,
    "storage_ok": 1,
    "net_ok": 1,
    "mem_ok": 1,
    "temp_ok": 1
  }
}
EOF

    cat > "$TEST_DIR/health_degraded.json" <<EOF
{
  "overall_score": 3,
  "overall_status": "degraded",
  "legacy_format": {
    "wdt_ok": 0,
    "ecc_ok": 1,
    "storage_ok": 1,
    "net_ok": 0,
    "mem_ok": 1,
    "temp_ok": 0
  }
}
EOF

    cat > "$TEST_DIR/health_critical.json" <<EOF
{
  "overall_score": 2,
  "overall_status": "critical",
  "legacy_format": {
    "wdt_ok": 0,
    "ecc_ok": 0,
    "storage_ok": 1,
    "net_ok": 0,
    "mem_ok": 1,
    "temp_ok": 0
  }
}
EOF
}

teardown() {
    echo "Cleaning up test environment..."
    rm -rf "$TEST_DIR"
}

test_start() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo ""
    printf "  Test %-3d: %-48s\n" "$TESTS_RUN" "$1"
    echo ""
}

test_assert() {
    local condition="$1"
    local message="$2"
    
    if $condition; then
        echo "   $message"
        return 0
    else
        echo "   FAILED: $message"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

test_end() {
    if [ "$TESTS_FAILED" -eq "$(($TESTS_RUN - $TESTS_PASSED))" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  -> Test PASSED"
    else
        echo "  -> Test FAILED"
    fi
}

test_tier1_to_tier2_promotion() {
    test_start "Tier-1 -> Tier-2 promotion (healthy system)"
    
    local journal="$TEST_DIR/test1.dat"
    $JOURNAL_TOOL init "$journal" >/dev/null 2>&1
    
    JOURNAL="$journal" \
    JOURNAL_TOOL="$JOURNAL_TOOL" \
    HEALTH_JSON="$TEST_DIR/health_healthy.json" \
    TIER2_ROOT="$TEST_DIR/tier2-root" \
    $POLICY_ENGINE >/dev/null 2>&1
    
    local exit_code=$?
    
    test_assert "[ $exit_code -eq 0 ]" "Exit code is 0 (promotion allowed)"
    
    local tier=$($JOURNAL_TOOL read "$journal" 2>/dev/null | grep "^  Tier:" | awk '{print $2}')
    test_assert "[ \"$tier\" = \"2\" ]" "Journal tier updated to 2"
    
    test_end
}

test_tier1_to_tier2_denied_health() {
    test_start "Tier-1 -> Tier-2 denied (poor health)"
    
    local journal="$TEST_DIR/test2.dat"
    $JOURNAL_TOOL init "$journal" >/dev/null 2>&1
    
    JOURNAL="$journal" \
    JOURNAL_TOOL="$JOURNAL_TOOL" \
    HEALTH_JSON="$TEST_DIR/health_critical.json" \
    TIER2_ROOT="$TEST_DIR/tier2-root" \
    $POLICY_ENGINE >/dev/null 2>&1
    
    local exit_code=$?
    
    test_assert "[ $exit_code -ne 0 ]" "Exit code is non-zero (promotion denied)"
    
    local tier=$($JOURNAL_TOOL read "$journal" 2>/dev/null | grep "^  Tier:" | awk '{print $2}')
    test_assert "[ \"$tier\" = \"1\" ]" "Journal tier stays at 1"
    
    local tries=$($JOURNAL_TOOL read "$journal" 2>/dev/null | grep "^  Tries T2:" | awk '{print $3}')
    test_assert "[ \"$tries\" = \"2\" ]" "Tier-2 tries decremented"
    
    test_end
}

test_tier1_to_tier2_denied_signature() {
    test_start "Tier-1 -> Tier-2 denied (signature verification failed)"
    
    local journal="$TEST_DIR/test3.dat"
    $JOURNAL_TOOL init "$journal" >/dev/null 2>&1
    
    JOURNAL="$journal" \
    JOURNAL_TOOL="$JOURNAL_TOOL" \
    HEALTH_JSON="$TEST_DIR/health_healthy.json" \
    TIER2_ROOT="/nonexistent/tier2-root" \
    $POLICY_ENGINE >/dev/null 2>&1
    
    local exit_code=$?
    
    test_assert "[ $exit_code -ne 0 ]" "Exit code is non-zero (promotion denied)"
    
    local tier=$($JOURNAL_TOOL read "$journal" 2>/dev/null | grep "^  Tier:" | awk '{print $2}')
    test_assert "[ \"$tier\" = \"1\" ]" "Journal tier stays at 1"
    
    test_end
}

test_tier2_to_tier3_promotion() {
    test_start "Tier-2 -> Tier-3 promotion (excellent health + network)"
    
    local journal="$TEST_DIR/test4.dat"
    $JOURNAL_TOOL init "$journal" >/dev/null 2>&1
    $JOURNAL_TOOL set-tier 2 "$journal" >/dev/null 2>&1
    
    JOURNAL="$journal" \
    JOURNAL_TOOL="$JOURNAL_TOOL" \
    HEALTH_JSON="$TEST_DIR/health_healthy.json" \
    TIER2_ROOT="$TEST_DIR/tier2-root" \
    TIER3_ROOT="$TEST_DIR/tier3-root" \
    $POLICY_ENGINE >/dev/null 2>&1
    
    local exit_code=$?
    
    test_assert "[ $exit_code -eq 0 ]" "Exit code is 0 (promotion allowed)"
    
    local tier=$($JOURNAL_TOOL read "$journal" 2>/dev/null | grep "^  Tier:" | awk '{print $2}')
    test_assert "[ \"$tier\" = \"3\" ]" "Journal tier updated to 3"
    
    test_end
}

test_tier2_to_tier3_denied_network() {
    test_start "Tier-2 -> Tier-3 denied (network required but unavailable)"
    
    local journal="$TEST_DIR/test5.dat"
    $JOURNAL_TOOL init "$journal" >/dev/null 2>&1
    $JOURNAL_TOOL set-tier 2 "$journal" >/dev/null 2>&1
    
    JOURNAL="$journal" \
    JOURNAL_TOOL="$JOURNAL_TOOL" \
    HEALTH_JSON="$TEST_DIR/health_degraded.json" \
    TIER2_ROOT="$TEST_DIR/tier2-root" \
    TIER3_ROOT="$TEST_DIR/tier3-root" \
    $POLICY_ENGINE >/dev/null 2>&1
    
    local exit_code=$?
    
    test_assert "[ $exit_code -ne 0 ]" "Exit code is non-zero (promotion denied)"
    
    local tier=$($JOURNAL_TOOL read "$journal" 2>/dev/null | grep "^  Tier:" | awk '{print $2}')
    test_assert "[ \"$tier\" = \"2\" ]" "Journal tier stays at 2"
    
    test_end
}

test_tier2_demotion_health_critical() {
    test_start "Tier-2 -> Tier-1 demotion (critical health)"
    
    local journal="$TEST_DIR/test6.dat"
    $JOURNAL_TOOL init "$journal" >/dev/null 2>&1
    $JOURNAL_TOOL set-tier 2 "$journal" >/dev/null 2>&1
    
    JOURNAL="$journal" \
    JOURNAL_TOOL="$JOURNAL_TOOL" \
    HEALTH_JSON="$TEST_DIR/health_critical.json" \
    TIER2_ROOT="$TEST_DIR/tier2-root" \
    $POLICY_ENGINE >/dev/null 2>&1
    
    local exit_code=$?
    
    test_assert "[ $exit_code -ne 0 ]" "Exit code is non-zero (demotion occurred)"
    
    local tier=$($JOURNAL_TOOL read "$journal" 2>/dev/null | grep "^  Tier:" | awk '{print $2}')
    test_assert "[ \"$tier\" = \"1\" ]" "Journal tier demoted to 1"
    
    test_end
}

test_attempts_exhausted() {
    test_start "Tier-2 attempts exhausted -> Emergency mode"
    
    local journal="$TEST_DIR/test7.dat"
    $JOURNAL_TOOL init "$journal" >/dev/null 2>&1
    $JOURNAL_TOOL dec-tries 2 "$journal" >/dev/null 2>&1
    $JOURNAL_TOOL dec-tries 2 "$journal" >/dev/null 2>&1
    $JOURNAL_TOOL dec-tries 2 "$journal" >/dev/null 2>&1
    
    JOURNAL="$journal" \
    JOURNAL_TOOL="$JOURNAL_TOOL" \
    HEALTH_JSON="$TEST_DIR/health_healthy.json" \
    TIER2_ROOT="$TEST_DIR/tier2-root" \
    $POLICY_ENGINE >/dev/null 2>&1
    
    local exit_code=$?
    
    test_assert "[ $exit_code -eq 2 ]" "Exit code is 2 (emergency mode)"
    
    local flags=$($JOURNAL_TOOL read "$journal" 2>/dev/null | grep "^  Flags:")
    test_assert "echo \"$flags\" | grep -q EMERGENCY" "Emergency flag set"
    test_assert "echo \"$flags\" | grep -q QUARANTINE" "Quarantine flag set"
    
    test_end
}

test_brownout_recovery() {
    test_start "Brownout recovery (wait before promotion)"
    
    local journal="$TEST_DIR/test8.dat"
    $JOURNAL_TOOL init "$journal" >/dev/null 2>&1
    $JOURNAL_TOOL set-flag brownout "$journal" >/dev/null 2>&1
    
    JOURNAL="$journal" \
    JOURNAL_TOOL="$JOURNAL_TOOL" \
    HEALTH_JSON="$TEST_DIR/health_healthy.json" \
    TIER2_ROOT="$TEST_DIR/tier2-root" \
    POLICY_BROWNOUT_WAIT_BOOTS=2 \
    $POLICY_ENGINE >/dev/null 2>&1
    
    local tier=$($JOURNAL_TOOL read "$journal" 2>/dev/null | grep "^  Tier:" | awk '{print $2}')
    test_assert "[ \"$tier\" = \"1\" ]" "Stays in Tier-1 during brownout recovery"
    
    $JOURNAL_TOOL inc-boot "$journal" >/dev/null 2>&1
    $JOURNAL_TOOL inc-boot "$journal" >/dev/null 2>&1
    
    JOURNAL="$journal" \
    JOURNAL_TOOL="$JOURNAL_TOOL" \
    HEALTH_JSON="$TEST_DIR/health_healthy.json" \
    TIER2_ROOT="$TEST_DIR/tier2-root" \
    POLICY_BROWNOUT_WAIT_BOOTS=2 \
    $POLICY_ENGINE >/dev/null 2>&1
    
    tier=$($JOURNAL_TOOL read "$journal" 2>/dev/null | grep "^  Tier:" | awk '{print $2}')
    test_assert "[ \"$tier\" = \"2\" ]" "Promotes after brownout recovery period"
    
    test_end
}

main() {
    echo ""
    echo "  PAC Policy Engine Test Suite                             "
    echo ""
    echo ""
    
    setup
    
    test_tier1_to_tier2_promotion
    test_tier1_to_tier2_denied_health
    test_tier1_to_tier2_denied_signature
    test_tier2_to_tier3_promotion
    test_tier2_to_tier3_denied_network
    test_tier2_demotion_health_critical
    test_attempts_exhausted
    test_brownout_recovery
    
    teardown
    
    echo ""
    echo ""
    echo "  TEST SUMMARY                                              "
    echo ""
    printf "  Total Tests:  %-3d                                         \n" "$TESTS_RUN"
    printf "  Passed:       %-3d                                         \n" "$TESTS_PASSED"
    printf "  Failed:       %-3d                                         \n" "$TESTS_FAILED"
    echo ""
    echo ""
    
    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo " All tests PASSED! Policy engine is working correctly."
        return 0
    else
        echo " Some tests FAILED. Please review the output above."
        return 1
    fi
}

cd "$(dirname "$0")/.." || exit 1
main "$@"

