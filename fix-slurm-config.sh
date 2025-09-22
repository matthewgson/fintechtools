#!/bin/bash
# Comprehensive SLURM configuration fix for container environment
# Handles JobAcctGatherParams conflicts and protocol compatibility

SLURM_CONF_FILE="/etc/slurm/slurm.conf"
SANITIZED_CONF="/tmp/slurm/slurm.conf.sanitized"

# Create sanitized config directory
mkdir -p /tmp/slurm

if [ -f "$SLURM_CONF_FILE" ]; then
    echo "Sanitizing SLURM configuration from: $SLURM_CONF_FILE"
    
    # Advanced sanitization to handle multiple conflicts
    awk 'BEGIN{IGNORECASE=1}
         /^\s*JobAcctGatherParams\s*=/{
             original=$0
             line=$0; gsub(/[ \t]/, "", line)
             split(line, a, "=")
             params = (a[1]=="JobAcctGatherParams") ? a[2] : line
             
             # Check for conflicting parameters
             has_pss = (params ~ /(^|,)UsePSS(,|$)/)
             has_noshared = (params ~ /(^|,)NoShared(,|$)/)
             
             if (has_pss && has_noshared) {
                 print "# WARNING: Removed conflicting NoShared option (conflicts with UsePSS)"
                 gsub(/(^|,)NoShared(,|$)/, ",", params)
             }
             
             # Clean up multiple commas and leading/trailing commas
             gsub(/,,+/, ",", params)
             sub(/^,/, "", params)
             sub(/,$/, "", params)
             
             # Use safe default if params is empty
             if (params == "" || params ~ /^[,\s]*$/) {
                 print "JobAcctGatherParams=UsePSS"
             } else {
                 print "JobAcctGatherParams=" params
             }
             next
         }
         { print }' "$SLURM_CONF_FILE" > "$SANITIZED_CONF"
else
    echo "No SLURM config found, creating minimal safe config"
    cat > "$SANITIZED_CONF" << EOF
# Minimal safe SLURM configuration for container
ClusterName=container_cluster
ControlMachine=localhost
SlurmUser=slurm
SlurmdUser=root
StateSaveLocation=/var/lib/slurm
SlurmdSpoolDir=/tmp/slurm
SwitchType=switch/none
MpiDefault=none
ProctrackType=proctrack/pgid
TaskPlugin=task/none
ReturnToService=2
JobAcctGatherType=jobacct_gather/none
AccountingStorageType=accounting_storage/none
NodeName=localhost CPUs=1 State=UNKNOWN
PartitionName=debug Nodes=localhost Default=YES MaxTime=INFINITE State=UP
EOF
fi

# Set environment variable
export SLURM_CONF="$SANITIZED_CONF"
echo "SLURM_CONF set to: $SLURM_CONF"