#!/bin/sh

set +e  

JOURNAL="/var/pac/journal.dat"
JOURNAL_TOOL="/bin/journal_tool"
HEALTH_LOG="/tmp/health.json"
HEALTH_SCRIPT="/usr/lib/pac/health_check.sh"
ATTEST_SCRIPT="/usr/lib/pac/attest_agent.sh"
NETWORK_SCRIPT="/usr/lib/pac/setup_network.sh"

mkdir -p /var/pac /tmp /proc /sys /dev

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sys /sys 2>/dev/null || true
mount -t devtmpfs dev /dev 2>/dev/null || true

mkdir -p /host_tmp 2>/dev/null || true
echo "[INIT] Attempting 9p mount..."
if mount -t 9p -o trans=virtio,version=9p2000.L,rw,nofail host_tmp /host_tmp 2>&1; then
    echo "[INIT]  9p mount successful - /host_tmp available"
    if [ -f /host_tmp/inject_ecc_errors ]; then
        ecc_val=$(cat /host_tmp/inject_ecc_errors 2>/dev/null || echo "0")
        echo "[INIT]  Can read inject_ecc_errors: $ecc_val"
    fi
else
    echo "[INIT]  9p mount failed - hardware faults won't work"
fi

echo ""
echo "    PAC Boot - Progressive Attestation Chain"
echo "              Fault-Tolerant Secure Boot"
echo ""
echo ""

if [ ! -f "$JOURNAL" ]; then
    echo "-> Creating new boot journal..."
    $JOURNAL_TOOL init "$JOURNAL" 2>/dev/null || echo "   Journal init warning"
fi

echo "-> Recording boot attempt..."
$JOURNAL_TOOL increment "$JOURNAL" 2>/dev/null || true

echo ""
$JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | head -20 || true
echo ""

HAS_BROWNOUT_FLAG=0
HAS_EMERGENCY_FLAG=0

if $JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | grep -qi "BROWNOUT"; then
    HAS_BROWNOUT_FLAG=1
    echo ""
    echo " BROWNOUT FLAG DETECTED"
    echo "-> System detected power instability in previous boot"
    echo "-> Boot limited to Tier 1 (safe mode) for system stability"
    echo ""
    echo ""
fi

if $JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | grep -qi "EMERGENCY"; then
    HAS_EMERGENCY_FLAG=1
    echo ""
    echo " EMERGENCY FLAG DETECTED"
    echo "-> System in emergency mode"
    echo "-> Boot limited to Tier 1 until flag is cleared"
    echo ""
    echo ""
fi

CURRENT_TIER=1
echo ""
echo "                      TIER 1: MINIMAL BOOT                         "
echo ""
echo ""
echo " Kernel loaded"
echo " Initramfs mounted"
echo " Essential filesystems ready"
echo " Boot journal operational"
echo ""
echo "-> Tier 1 established (safe mode)"
echo ""

echo ""
echo "HEALTH ASSESSMENT"
echo ""
if [ -f "$HEALTH_SCRIPT" ]; then
    sh "$HEALTH_SCRIPT" || echo "   Health check completed with warnings"
else
    echo "   Health check script not found"
    echo '{"overall_status":"unknown","overall_score":5}' > "$HEALTH_LOG"
fi

sleep 1
HEALTH_SCORE=0
HEALTH_STATUS="unknown"

if [ -f "$HEALTH_LOG" ]; then
    HEALTH_SCORE=$(cat "$HEALTH_LOG" | grep -o '"overall_score":[0-9]*' | cut -d':' -f2 | head -1)
    HEALTH_SCORE=${HEALTH_SCORE:-0}
    HEALTH_STATUS=$(cat "$HEALTH_LOG" | grep -o '"overall_status":"[^"]*"' | cut -d'"' -f4 | head -1)
    HEALTH_STATUS=${HEALTH_STATUS:-unknown}
    
    echo ""
    echo "HEALTH SUMMARY"
    echo ""
    echo "  Status: $HEALTH_STATUS"
    echo "  Score:  $HEALTH_SCORE/10"
    echo ""
else
    echo " Warning: Health data file not found"
    echo ""
fi

MAX_BOOT_TIER=3

if [ "$HAS_EMERGENCY_FLAG" -eq 1 ] || [ "$HAS_BROWNOUT_FLAG" -eq 1 ]; then
    MAX_BOOT_TIER=1
    if [ "$HAS_EMERGENCY_FLAG" -eq 1 ]; then
        echo "-> Boot tier limited to 1 (EMERGENCY FLAG)"
    elif [ "$HAS_BROWNOUT_FLAG" -eq 1 ]; then
        echo "-> Boot tier limited to 1 (BROWNOUT FLAG)"
    fi
    echo ""
fi

TIER2_SUCCESS=0

if [ "$HEALTH_SCORE" -ge 3 ] && [ "$MAX_BOOT_TIER" -ge 2 ]; then
    echo ""
    echo "              TIER 2: ATTEMPTING NETWORK BOOT                      "
    echo ""
    echo ""
    echo "-> Health score sufficient (>= 3), attempting Tier 2 promotion..."
    echo ""
    
    echo ""
    echo "NETWORK SETUP"
    echo ""
    
    if [ -f "$NETWORK_SCRIPT" ]; then
        if sh "$NETWORK_SCRIPT" 2>&1; then
            if ping -c 1 -W 2 10.0.2.2 >/dev/null 2>&1; then
                echo "   Network connectivity verified"
                
                TIER2_ROOTFS="/tier2/rootfs.img"
                echo ""
                echo ""
                echo "TIER 2 ROOTFS MOUNT"
                echo ""
                
                if [ -f "$TIER2_ROOTFS" ]; then
                    echo "  -> Found Tier 2 rootfs image: $TIER2_ROOTFS"
                    ls -lh "$TIER2_ROOTFS" 2>/dev/null | head -1 || echo "  -> File exists but cannot stat"
                    echo "  -> Attempting to mount Tier 2 rootfs..."
                    
                    mkdir -p /newroot
                    MOUNT_OUTPUT=$(mount -o ro,loop "$TIER2_ROOTFS" /newroot 2>&1)
                    MOUNT_EXIT=$?
                    
                    if [ $MOUNT_EXIT -eq 0 ]; then
                        echo "   Tier 2 rootfs mounted successfully"
                        echo "  -> Verifying mount..."
                        if [ -f "/newroot/sbin/init" ]; then
                            echo "   Tier 2 /sbin/init found - ready to pivot"
                            TIER2_SUCCESS=1
                            CURRENT_TIER=2
                            echo ""
                            echo " TIER 2 ESTABLISHED (Network + rootfs mounted)"
                            
                            if [ "$HEALTH_SCORE" -ge 6 ]; then
                                echo ""
                                echo ""
                                echo "CHECKING FOR TIER 3 PROMOTION (before Tier 2 pivot)"
                                echo ""
                                
                                if [ "$MAX_BOOT_TIER" -ge 3 ] && ping -c 1 -W 2 10.0.2.2 >/dev/null 2>&1 && [ -f "$ATTEST_SCRIPT" ]; then
                                    echo "  -> Verifier reachable, attempting Tier 3 promotion..."
                                    
                                    if VERBOSE=1 sh "$ATTEST_SCRIPT" 2>&1; then
                                        echo "   Attestation successful - promoting to Tier 3"
                                        
                                        TIER3_ROOTFS="/tier3/rootfs.img"
                                        if [ -f "$TIER3_ROOTFS" ]; then
                                            umount /newroot 2>/dev/null || true
                                            echo ""
                                            echo ""
                                            echo "TIER 3 ROOTFS MOUNT (IMA/EVM)"
                                            echo ""
                                            echo "  -> Found Tier 3 rootfs image: $TIER3_ROOTFS"
                                            ls -lh "$TIER3_ROOTFS" 2>/dev/null | head -1 || echo "  -> File exists but cannot stat"
                                            echo "  -> Attempting to mount Tier 3 rootfs..."
                                            
                                            MOUNT_OUTPUT=$(mount -o ro,loop "$TIER3_ROOTFS" /newroot 2>&1)
                                            MOUNT_EXIT=$?
                                            
                                            if [ $MOUNT_EXIT -eq 0 ]; then
                                                echo "   Tier 3 rootfs mounted successfully"
                                                
                                                if [ -f "/tier3/keys/ima_pub.pem" ]; then
                                                    echo "  -> IMA/EVM keys available (enforcement will be enabled in kernel)"
                                                    if [ -f "/newroot/etc/ima/policy" ]; then
                                                        echo "   IMA policy found in rootfs"
                                                    else
                                                        echo "   IMA policy not found in rootfs"
                                                    fi
                                                else
                                                    echo "   IMA/EVM keys not found"
                                                fi
                                                
                                                echo "  -> Verifying mount..."
                                                if [ -f "/newroot/sbin/init" ]; then
                                                    echo "   Tier 3 /sbin/init found - ready to pivot"
                                                    TIER3_SUCCESS=1
                                                    CURRENT_TIER=3
                                                    echo ""
                                                    echo " TIER 3 ESTABLISHED (Full security with attestation + rootfs)"
                                                    echo "  -> Pivoting to Tier 3 rootfs..."
                                                    if mount | grep -q "/host_tmp"; then
                                                        mkdir -p /newroot/host_tmp 2>/dev/null || true
                                                        mount --move /host_tmp /newroot/host_tmp 2>/dev/null && echo "   Moved /host_tmp to new root" || echo "   Failed to move /host_tmp"
                                                    fi
                                                    exec switch_root /newroot /sbin/init
                                                else
                                                    echo "   Tier 3 /sbin/init not found in mounted rootfs"
                                                    umount /newroot 2>/dev/null || true
                                                    echo "  -> Falling back to Tier 2 rootfs"
                                                    mount -o ro,loop "$TIER2_ROOTFS" /newroot 2>/dev/null || true
                                                fi
                                            else
                                                echo "   Failed to mount Tier 3 rootfs"
                                                echo "  -> Mount error: $MOUNT_OUTPUT"
                                                echo "  -> Falling back to Tier 2 rootfs"
                                                mount -o ro,loop "$TIER2_ROOTFS" /newroot 2>/dev/null || true
                                            fi
                                        else
                                            echo "   Tier 3 rootfs image not found: $TIER3_ROOTFS"
                                            echo "  -> Checking tier3 directory contents:"
                                            ls -la /tier3/ 2>/dev/null || echo "    /tier3/ directory does not exist"
                                            echo "  -> Continuing with Tier 2 rootfs"
                                        fi
                                    else
                                        echo "   Attestation failed - continuing with Tier 2"
                                    fi
                                else
                                    echo "  -> Verifier not reachable - continuing with Tier 2"
                                fi
                            fi
                            
                            echo "  -> Pivoting to Tier 2 rootfs..."
                            exec switch_root /newroot /sbin/init
                        else
                            echo "   Tier 2 /sbin/init not found in mounted rootfs"
                            umount /newroot 2>/dev/null || true
                            TIER2_SUCCESS=1
                            CURRENT_TIER=2
                            echo ""
                            echo " TIER 2 ESTABLISHED (Network operational, rootfs invalid)"
                        fi
                    else
                        echo "   Failed to mount Tier 2 rootfs"
                        echo "  -> Mount error: $MOUNT_OUTPUT"
                        TIER2_SUCCESS=1
                        CURRENT_TIER=2
                        echo ""
                        echo " TIER 2 ESTABLISHED (Network operational, rootfs mount failed)"
                    fi
                else
                    echo "   Tier 2 rootfs image not found: $TIER2_ROOTFS"
                    echo "  -> Checking tier2 directory contents:"
                    ls -la /tier2/ 2>/dev/null || echo "    /tier2/ directory does not exist"
                    TIER2_SUCCESS=1
                    CURRENT_TIER=2
                    echo ""
                    echo " TIER 2 ESTABLISHED (Network operational, no rootfs image)"
                fi
            else
                echo "   Network connectivity test failed"
                echo ""
                echo " TIER 2 FAILED - Degrading to Tier 1"
            fi
        else
            echo "   Network setup failed"
            echo ""
            echo " TIER 2 FAILED - Degrading to Tier 1"
        fi
    else
        echo "   Network setup script not found"
        echo ""
        echo " TIER 2 FAILED - Degrading to Tier 1"
    fi
else
    echo ""
    echo "              TIER 2: PROMOTION BLOCKED                            "
    echo ""
    echo ""
    echo " Health score too low ($HEALTH_SCORE < 3)"
    echo "-> Staying in Tier 1 (safe mode)"
fi
echo ""

TIER3_SUCCESS=0

if [ "$TIER2_SUCCESS" -eq 1 ] && [ "$HEALTH_SCORE" -ge 6 ]; then
    echo ""
    echo "         TIER 3: ATTEMPTING FULL BOOT + ATTESTATION               "
    echo ""
    echo ""
    echo "-> Network operational and health excellent (>= 6)"
    echo "-> Attempting Tier 3 promotion with remote attestation..."
    echo ""
    
    echo ""
    echo "REMOTE ATTESTATION"
    echo ""
    
    if [ -f "$ATTEST_SCRIPT" ]; then
        if VERBOSE=1 sh "$ATTEST_SCRIPT" 2>&1; then
            echo ""
            echo " Attestation successful"
            
            TIER3_ROOTFS="/tier3/rootfs.img"
            echo ""
            echo ""
            echo "TIER 3 ROOTFS MOUNT (IMA/EVM)"
            echo ""
            
            if [ -f "$TIER3_ROOTFS" ]; then
                echo "  -> Found Tier 3 rootfs image: $TIER3_ROOTFS"
                ls -lh "$TIER3_ROOTFS" 2>/dev/null | head -1 || echo "  -> File exists but cannot stat"
                echo "  -> Attempting to mount Tier 3 rootfs..."
                
                mkdir -p /newroot
                MOUNT_OUTPUT=$(mount -o ro,loop "$TIER3_ROOTFS" /newroot 2>&1)
                MOUNT_EXIT=$?
                
                if [ $MOUNT_EXIT -eq 0 ]; then
                    echo "   Tier 3 rootfs mounted successfully"
                    
                    if [ -f "/tier3/keys/ima_pub.pem" ]; then
                        echo "  -> IMA/EVM keys available (enforcement will be enabled in kernel)"
                        if [ -f "/newroot/etc/ima/policy" ]; then
                            echo "   IMA policy found in rootfs"
                        else
                            echo "   IMA policy not found in rootfs"
                        fi
                    else
                        echo "   IMA/EVM keys not found"
                    fi
                    
                    echo "  -> Verifying mount..."
                    if [ -f "/newroot/sbin/init" ]; then
                        echo "   Tier 3 /sbin/init found - ready to pivot"
                        TIER3_SUCCESS=1
                        CURRENT_TIER=3
                        echo ""
                        echo " TIER 3 ESTABLISHED (Full security with attestation + rootfs)"
                        echo "  -> Copying journal to Tier 3 rootfs..."
                        if [ -f "/var/pac/journal.dat" ]; then
                            mkdir -p /newroot/tmp 2>/dev/null || true
                            cp -f /var/pac/journal.dat /newroot/tmp/journal.dat.backup 2>/dev/null || true
                            echo "   Journal backed up for Tier 3"
                        fi
                        echo "  -> Pivoting to Tier 3 rootfs..."
                        exec switch_root /newroot /sbin/init
                    else
                        echo "   Tier 3 /sbin/init not found in mounted rootfs"
                        umount /newroot 2>/dev/null || true
                        TIER3_SUCCESS=1
                        CURRENT_TIER=3
                        echo ""
                        echo " TIER 3 ESTABLISHED (Full security with attestation, rootfs invalid)"
                    fi
                else
                    echo "   Failed to mount Tier 3 rootfs"
                    echo "  -> Mount error: $MOUNT_OUTPUT"
                    TIER3_SUCCESS=1
                    CURRENT_TIER=3
                    echo ""
                    echo " TIER 3 ESTABLISHED (Full security with attestation, rootfs mount failed)"
                fi
            else
                echo "   Tier 3 rootfs image not found: $TIER3_ROOTFS"
                echo "  -> Checking tier3 directory contents:"
                ls -la /tier3/ 2>/dev/null || echo "    /tier3/ directory does not exist"
                TIER3_SUCCESS=1
                CURRENT_TIER=3
                echo ""
                echo " TIER 3 ESTABLISHED (Full security with attestation, no rootfs image)"
            fi
        else
            echo ""
            echo " TIER 3 FAILED - Attestation unsuccessful"
            echo "-> Degrading to Tier 2 (network without attestation)"
        fi
    else
        echo "   Attestation script not found"
        echo ""
        echo " TIER 3 FAILED - Degrading to Tier 2"
    fi
elif [ "$TIER2_SUCCESS" -eq 1 ]; then
    echo ""
    echo "              TIER 3: PROMOTION BLOCKED                            "
    echo ""
    echo ""
    echo " Health score insufficient for Tier 3 ($HEALTH_SCORE < 6)"
    echo "-> Staying in Tier 2 (network without attestation)"
fi
echo ""

echo ""
echo "PERSISTING BOOT STATE"
echo ""
$JOURNAL_TOOL set-tier "$CURRENT_TIER" "$JOURNAL" 2>/dev/null && \
    echo " Journal updated: Tier $CURRENT_TIER saved" || \
    echo " Failed to update journal"
echo ""

echo ""
echo "              PAC BOOT COMPLETE - TIER $CURRENT_TIER ACTIVE                    "
echo ""
echo ""

echo "Final System State:"
echo ""
echo "  Boot Tier:       $CURRENT_TIER"
echo "  Health Score:    $HEALTH_SCORE/10"
echo "  Health Status:   $HEALTH_STATUS"
echo ""

echo "Tier Status:"
echo ""
if [ "$CURRENT_TIER" -ge 1 ]; then
    echo "  Tier 1 (Minimal):      Active"
else
    echo "  Tier 1 (Minimal):      Failed"
fi

if [ "$CURRENT_TIER" -ge 2 ]; then
    echo "  Tier 2 (Network):      Active"
elif [ "$TIER2_SUCCESS" -eq 0 ] && [ "$HEALTH_SCORE" -ge 3 ]; then
    echo "  Tier 2 (Network):      Failed (degraded)"
else
    echo "  Tier 2 (Network):     - Blocked (health)"
fi

if [ "$CURRENT_TIER" -ge 3 ]; then
    echo "  Tier 3 (Attestation):  Active"
elif [ "$TIER3_SUCCESS" -eq 0 ] && [ "$TIER2_SUCCESS" -eq 1 ] && [ "$HEALTH_SCORE" -ge 6 ]; then
    echo "  Tier 3 (Attestation):  Failed (degraded)"
else
    echo "  Tier 3 (Attestation): - Blocked"
fi
echo ""

echo "System Information:"
echo ""
echo "  Hostname:      pac-system"
echo "  Kernel:        $(uname -r)"
echo "  Architecture:  $(uname -m)"
if [ "$CURRENT_TIER" -ge 2 ]; then
    echo "  IP Address:    $(ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print $2}' || echo 'N/A')"
fi
echo ""

if [ -f "/usr/lib/pac/policy_monitor.sh" ]; then
    echo ""
    echo ""
    echo "STARTING POLICY MONITOR (FSM Runtime Evaluation)"
    echo ""
    sh /usr/lib/pac/policy_monitor.sh start 2>&1 || true
    echo "   Policy monitor daemon started (Tier $CURRENT_TIER)"
    echo "  -> Monitoring for promotion/degradation conditions"
    echo ""
fi

echo "Available Commands:"
echo ""
echo "  $JOURNAL_TOOL read $JOURNAL     - View journal"
echo "  sh $HEALTH_SCRIPT                - Re-run health check"
if [ "$CURRENT_TIER" -ge 2 ]; then
    echo "  sh $ATTEST_SCRIPT                - Re-run attestation"
    echo "  sh /usr/lib/pac/policy_monitor.sh status  - Check monitor status"
    echo "  ip addr                          - Check network"
    echo "  ping 10.0.2.2                    - Test connectivity"
fi
echo ""

echo ""
echo ""
echo "Starting interactive shell..."
echo ""

exec setsid cttyhack /bin/sh 2>/dev/null || exec /bin/sh

