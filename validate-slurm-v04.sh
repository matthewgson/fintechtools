#!/bin/bash
# SLURM Validation Script for v0.4 Container
# Validates that SLURM configuration fixes are working properly

echo "========================================="
echo "SLURM v0.4 Container Validation"
echo "========================================="

# Test 1: Check if fix script exists and is executable
echo "1. Checking fix-slurm-config.sh script:"
if [ -f "/usr/local/bin/fix-slurm-config.sh" ]; then
    echo "   ✓ Script exists at /usr/local/bin/fix-slurm-config.sh"
    if [ -x "/usr/local/bin/fix-slurm-config.sh" ]; then
        echo "   ✓ Script is executable"
    else
        echo "   ❌ Script is not executable"
    fi
else
    echo "   ❌ Script not found"
fi

# Test 2: Run the fix script
echo ""
echo "2. Running SLURM configuration fix:"
if [ -f "/usr/local/bin/fix-slurm-config.sh" ]; then
    echo "   Executing fix script..."
    /usr/local/bin/fix-slurm-config.sh
    
    # Check if sanitized config was created
    if [ -f "/tmp/slurm/slurm.conf.sanitized" ]; then
        echo "   ✓ Sanitized configuration created"
        echo "   Location: /tmp/slurm/slurm.conf.sanitized"
    else
        echo "   ❌ Sanitized configuration not created"
    fi
else
    echo "   ❌ Cannot run fix script (not found)"
fi

# Test 3: Validate sanitized configuration
echo ""
echo "3. Validating sanitized configuration:"
if [ -f "/tmp/slurm/slurm.conf.sanitized" ]; then
    # Check for actual conflicts (excluding comment lines)
    if grep -v '^#' "/tmp/slurm/slurm.conf.sanitized" | grep -i "JobAcctGatherParams.*UsePSS.*NoShared\|JobAcctGatherParams.*NoShared.*UsePSS" >/dev/null 2>&1; then
        echo "   ❌ Conflict still present in sanitized config"
    else
        echo "   ✓ No conflicts detected in sanitized config"
    fi
    
    # Show JobAcctGatherParams line if present
    if grep -i "JobAcctGatherParams" "/tmp/slurm/slurm.conf.sanitized" >/dev/null 2>&1; then
        echo "   JobAcctGatherParams setting:"
        grep -i "JobAcctGatherParams" "/tmp/slurm/slurm.conf.sanitized" | sed 's/^/     /'
    fi
else
    echo "   ❌ Sanitized configuration not available for validation"
fi

# Test 4: Test SLURM commands with sanitized config
echo ""
echo "4. Testing SLURM commands with sanitized configuration:"
if [ -f "/tmp/slurm/slurm.conf.sanitized" ]; then
    export SLURM_CONF="/tmp/slurm/slurm.conf.sanitized"
    echo "   Set SLURM_CONF to sanitized config"
    
    if command -v sacct >/dev/null 2>&1; then
        echo "   Testing sacct --version with sanitized config..."
        SACCT_OUTPUT=$(sacct --version 2>&1)
        if echo "$SACCT_OUTPUT" | grep -i "fatal.*mutually exclusive" >/dev/null 2>&1; then
            echo "   ❌ Still getting mutual exclusivity error"
            echo "   Error: $SACCT_OUTPUT"
        elif echo "$SACCT_OUTPUT" | grep -i "slurm" >/dev/null 2>&1; then
            echo "   ✓ sacct working with sanitized config"
            echo "   Output: $SACCT_OUTPUT"
        else
            echo "   ⚠ Unexpected output: $SACCT_OUTPUT"
        fi
    else
        echo "   ❌ sacct command not available"
    fi
else
    echo "   ❌ Cannot test (no sanitized config)"
fi

# Test 5: Check environment integration
echo ""
echo "5. Checking environment integration:"
if grep -q "fix-slurm-config.sh" ~/.bashrc 2>/dev/null; then
    echo "   ✓ Fix script integrated into .bashrc"
else
    echo "   ❌ Fix script not found in .bashrc"
fi

if grep -q "SLURM_CONF=/tmp/slurm/slurm.conf.sanitized" ~/.bashrc 2>/dev/null; then
    echo "   ✓ Sanitized config export found in .bashrc"
else
    echo "   ❌ Sanitized config export not found in .bashrc"
fi

echo ""
echo "========================================="
echo "Validation Complete"
echo "========================================="

# Summary
echo ""
echo "Summary:"
if [ -f "/tmp/slurm/slurm.conf.sanitized" ] && ! grep -v '^#' "/tmp/slurm/slurm.conf.sanitized" | grep -i "JobAcctGatherParams.*UsePSS.*NoShared\|JobAcctGatherParams.*NoShared.*UsePSS" >/dev/null 2>&1; then
    echo "✅ SLURM configuration appears to be properly fixed"
else
    echo "❌ SLURM configuration issues may still exist"
fi