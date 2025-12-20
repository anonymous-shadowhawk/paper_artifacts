#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAULTLAB_DIR="${SCRIPT_DIR}/faultlab"

check_sudo() {
    if [ "$EUID" -ne 0 ]; then 
        echo "This script needs elevated privileges to run QEMU and manage TPM"
        echo "Requesting sudo access..."
        exec sudo "$0" "$@"
        exit 1
    fi
}

check_sudo "$@"

echo "COMPLETE PAC EXPERIMENTAL EVALUATION"
echo ""
echo "PHASE 1: BOOT-TIME FAULTS (5 types x 100 trials = 500)"
echo "  bit_flip, torn_write, signature, brownout, power_cut"
echo ""
echo "PHASE 2: RUNTIME FAULTS (5 types x 100 trials = 500)"
echo "  verifier_kill, storage, temperature, ecc, watchdog"
echo ""
echo "PHASE 3: RECOVERY TESTING (1 type x 100 trials = 100)"
echo "  verifier_kill (service recovery and promotion)"
echo ""
echo "TOTAL: 1,100 experiments"
echo "Estimated time: ~38-42 hours"
echo ""
echo "Results: /tmp/pac_complete_results_$(date +%Y%m%d_%H%M%S)"
echo ""
read -p "Press Enter to start (or Ctrl+C to cancel)..."

cd "${FAULTLAB_DIR}"
RESULTS_DIR="/tmp/pac_complete_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"
LOG_FILE="$RESULTS_DIR/master.log"

echo "" | tee -a "$LOG_FILE"
echo "[$(date '+%H:%M:%S')] Initial cleanup..." | tee -a "$LOG_FILE"
pkill -9 qemu swtpm 2>/dev/null || true
rm -f /tmp/inject_* /tmp/swtpm*.sock /tmp/sh* 2>/dev/null
rm -rf /tmp/tpm-state* 2>/dev/null
sleep 3
echo "  Cleanup complete" | tee -a "$LOG_FILE"

TOTAL_EXPERIMENTS=1100
COMPLETED=0
START_TIME=$(date +%s)

update_progress() {
    local fault=$1
    local trials=$2
    COMPLETED=$((COMPLETED + trials))
    local elapsed=$(($(date +%s) - START_TIME))
    local rate=$(echo "scale=2; $elapsed / $COMPLETED" | bc 2>/dev/null || echo "0")
    local remaining=$((TOTAL_EXPERIMENTS - COMPLETED))
    local eta=$(echo "$remaining * $rate / 60" | bc 2>/dev/null || echo "N/A")
    
    echo "" | tee -a "$LOG_FILE"
    echo "PROGRESS: $COMPLETED / $TOTAL_EXPERIMENTS experiments complete ($(($COMPLETED * 100 / $TOTAL_EXPERIMENTS))%)" | tee -a "$LOG_FILE"
    echo "Elapsed: $(($elapsed / 60)) minutes | ETA: ${eta} minutes" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

echo "" | tee -a "$LOG_FILE"
echo "PHASE 1/3: BOOT-TIME FAULTS (5 types x 100 trials = 500)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
echo "Estimated time: ~17 hours" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

BOOT_FAULTS="bit_flip torn_write signature brownout power_cut"
BOOT_COUNT=0

for fault in $BOOT_FAULTS; do
    BOOT_COUNT=$((BOOT_COUNT + 1))
    echo "" | tee -a "$LOG_FILE"
    echo "  [$BOOT_COUNT/5] Testing: $fault (boot-time, 100 trials)" | tee -a "$LOG_FILE"
    echo "  Started: $(date '+%H:%M:%S')" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    
    python3 pac_fault_injector.py \
        --fault "$fault" \
        --trials 100 \
        --trial-delay 5 \
        --timeout 240 \
        2>&1 | tee "$RESULTS_DIR/boot_${fault}.log" | \
        grep -E "TRIAL|Tier Reached|Boot Time|CAMPAIGN COMPLETE|Success Rate|TIER DISTRIBUTION|BOOT ANALYSIS"
    
    update_progress "$fault" 100
    sleep 3
done

echo "" | tee -a "$LOG_FILE"
echo "PHASE 2/3: RUNTIME FAULTS (5 types x 100 trials = 500)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
echo "Estimated time: ~17.5 hours" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

RUNTIME_FAULTS="verifier_kill storage temperature ecc watchdog"
RUNTIME_COUNT=0

for fault in $RUNTIME_FAULTS; do
    RUNTIME_COUNT=$((RUNTIME_COUNT + 1))
    echo "" | tee -a "$LOG_FILE"
    echo "  [$RUNTIME_COUNT/5] Testing: $fault (runtime, 100 trials)" | tee -a "$LOG_FILE"
    echo "  Started: $(date '+%H:%M:%S')" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    
    python3 pac_fault_injector.py \
        --fault "$fault" \
        --trials 100 \
        --trial-delay 5 \
        --timeout 240 \
        2>&1 | tee "$RESULTS_DIR/runtime_${fault}.log" | \
        grep -E "TRIAL|Initial Tier|Final Tier|Degraded|MTTD|CAMPAIGN COMPLETE|Success Rate|Detection|TIER DISTRIBUTION"
    
    update_progress "$fault" 100
    sleep 3
done

echo "" | tee -a "$LOG_FILE"
echo "PHASE 3/3: RECOVERY TESTING (1 type x 100 trials = 100)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
echo "Estimated time: ~3.5 hours" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "  Testing: verifier_kill (recovery, 100 trials)" | tee -a "$LOG_FILE"
echo "  Started: $(date '+%H:%M:%S')" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

python3 pac_fault_injector.py \
    --fault verifier_kill \
    --trials 100 \
    --test-recovery \
    --trial-delay 5 \
    --timeout 240 \
    2>&1 | tee "$RESULTS_DIR/recovery_verifier_kill.log" | \
    grep -E "TRIAL|Recovery|MTTR|CAMPAIGN COMPLETE|Success Rate|recovered"

update_progress "verifier_kill_recovery" 100

TOTAL_TIME=$(($(date +%s) - START_TIME))
HOURS=$((TOTAL_TIME / 3600))
MINUTES=$(((TOTAL_TIME % 3600) / 60))

echo "" | tee -a "$LOG_FILE"
echo "ALL EXPERIMENTS COMPLETE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Total experiments: $COMPLETED / $TOTAL_EXPERIMENTS" | tee -a "$LOG_FILE"
echo "Total time: ${HOURS}h ${MINUTES}m" | tee -a "$LOG_FILE"
echo "Results directory: $RESULTS_DIR" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Logs saved:" | tee -a "$LOG_FILE"
echo "  Master log: $LOG_FILE" | tee -a "$LOG_FILE"
echo "  Individual logs: $RESULTS_DIR/*.log" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "Generated files:" | tee -a "$LOG_FILE"
ls -lh "$RESULTS_DIR"/*.log 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "SUMMARY OF RESULTS" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "BOOT-TIME FAULTS (100 trials each):" | tee -a "$LOG_FILE"
for fault in $BOOT_FAULTS; do
    if [ -f "$RESULTS_DIR/boot_${fault}.log" ]; then
        success_rate=$(grep "Success Rate:" "$RESULTS_DIR/boot_${fault}.log" | tail -1 | awk '{print $3}' || echo "N/A")
        tier_dist=$(grep -A3 "TIER DISTRIBUTION" "$RESULTS_DIR/boot_${fault}.log" | tail -3 | tr '\n' ' ' || echo "N/A")
        echo "  $fault: $success_rate | $tier_dist" | tee -a "$LOG_FILE"
    fi
done
echo "" | tee -a "$LOG_FILE"

echo "RUNTIME FAULTS (100 trials each):" | tee -a "$LOG_FILE"
for fault in $RUNTIME_FAULTS; do
    if [ -f "$RESULTS_DIR/runtime_${fault}.log" ]; then
        degraded=$(grep -c "Degraded.*Yes" "$RESULTS_DIR/runtime_${fault}.log" 2>/dev/null || echo "0")
        percent=$((degraded * 100 / 100))
        
        mttd_values=$(grep "MTTD:" "$RESULTS_DIR/runtime_${fault}.log" | grep -v "None" | awk '{print $2}' | sed 's/s$//' || echo "")
        if [ -n "$mttd_values" ]; then
            avg_mttd=$(echo "$mttd_values" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "N/A"}')
            echo "  $fault: ${degraded}/100 degraded (${percent}%) | Avg MTTD: ${avg_mttd}s" | tee -a "$LOG_FILE"
        else
            echo "  $fault: ${degraded}/100 degraded (${percent}%)" | tee -a "$LOG_FILE"
        fi
    fi
done
echo "" | tee -a "$LOG_FILE"

echo "RECOVERY (100 trials):" | tee -a "$LOG_FILE"
if [ -f "$RESULTS_DIR/recovery_verifier_kill.log" ]; then
    recovered=$(grep -c "Recovery.*Yes" "$RESULTS_DIR/recovery_verifier_kill.log" 2>/dev/null || echo "0")
    percent=$((recovered * 100 / 100))
    
    mttr_values=$(grep "MTTR:" "$RESULTS_DIR/recovery_verifier_kill.log" | awk '{print $2}' | sed 's/s$//' || echo "")
    if [ -n "$mttr_values" ]; then
        avg_mttr=$(echo "$mttr_values" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "N/A"}')
        echo "  verifier_kill: ${recovered}/100 recovered (${percent}%) | Avg MTTR: ${avg_mttr}s" | tee -a "$LOG_FILE"
    else
        echo "  verifier_kill: ${recovered}/100 recovered (${percent}%)" | tee -a "$LOG_FILE"
    fi
fi
echo "" | tee -a "$LOG_FILE"

echo "All experiments completed successfully!" | tee -a "$LOG_FILE"
echo "Check detailed results in: $RESULTS_DIR" | tee -a "$LOG_FILE"
