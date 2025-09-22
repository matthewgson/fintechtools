#!/bin/bash
# SLURM Diagnostic Script
# Diagnoses SLURM configuration conflicts and compatibility issues

echo "========================================="
echo "SLURM System Diagnostic"
echo "========================================="

# Check SLURM installation
echo "1. Checking SLURM Installation:"
if command -v sacct >/dev/null 2>&1; then
    echo "   ✓ SLURM commands available"
    echo "   Version: $(sacct --version 2>&1 | head -1)"
else
    echo "   ❌ SLURM commands not found"
fi

# Check SLURM configuration
echo ""
echo "2. Checking SLURM Configuration:"
SLURM_CONF_PATHS=("/etc/slurm/slurm.conf" "/etc/slurm-llnl/slurm.conf" "$SLURM_CONF")

for conf_path in "${SLURM_CONF_PATHS[@]}"; do
    if [ -n "$conf_path" ] && [ -f "$conf_path" ]; then
        echo "   Found config: $conf_path"
        
        # Check for JobAcctGatherParams conflicts
        if grep -i "JobAcctGatherParams" "$conf_path" >/dev/null 2>&1; then
            echo "   JobAcctGatherParams line:"
            grep -i "JobAcctGatherParams" "$conf_path" | sed 's/^/     /'
            
            # Check for specific conflicts
            if grep -i "JobAcctGatherParams.*UsePSS.*NoShared\|JobAcctGatherParams.*NoShared.*UsePSS" "$conf_path" >/dev/null 2>&1; then
                echo "   ❌ CONFLICT DETECTED: UsePSS and NoShared are mutually exclusive"
            else
                echo "   ✓ No obvious conflicts detected"
            fi
        else
            echo "   No JobAcctGatherParams found"
        fi
        break
    fi
done

# Check Munge
echo ""
echo "3. Checking Munge Authentication:"
if command -v munge >/dev/null 2>&1; then
    echo "   ✓ Munge commands available"
    
    # Check munge socket
    MUNGE_SOCKETS=("/var/run/munge/munge.socket.2" "/run/munge/munge.socket.2" "$MUNGE_SOCKET")
    for socket in "${MUNGE_SOCKETS[@]}"; do
        if [ -n "$socket" ] && [ -S "$socket" ]; then
            echo "   ✓ Munge socket found: $socket"
            break
        fi
    done
else
    echo "   ❌ Munge not available"
fi

# Test SLURM commands
echo ""
echo "4. Testing SLURM Commands:"
if command -v sacct >/dev/null 2>&1; then
    echo "   Testing sacct --version..."
    SACCT_OUTPUT=$(sacct --version 2>&1)
    if echo "$SACCT_OUTPUT" | grep -i "fatal.*mutually exclusive" >/dev/null 2>&1; then
        echo "   ❌ JobAcctGatherParams conflict detected in command execution"
        echo "   Error: $SACCT_OUTPUT"
    elif echo "$SACCT_OUTPUT" | grep -i "slurm" >/dev/null 2>&1; then
        echo "   ✓ sacct working correctly"
    else
        echo "   ⚠ Unexpected sacct output: $SACCT_OUTPUT"
    fi
else
    echo "   ❌ sacct command not available"
fi

# Environment variables
echo ""
echo "5. SLURM Environment Variables:"
echo "   SLURM_CONF: ${SLURM_CONF:-'not set'}"
echo "   MUNGE_SOCKET: ${MUNGE_SOCKET:-'not set'}"

echo ""
echo "========================================="
echo "Diagnostic Complete"
echo "========================================="