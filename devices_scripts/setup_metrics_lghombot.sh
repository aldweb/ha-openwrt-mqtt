#!/bin/sh

# ============================================================
# Setup script for LG Hombot monitoring to Home Assistant
# ============================================================

echo "========================================="
echo "LG Hombot Monitoring Setup"
echo "========================================="
echo ""

# ============================================================
# Detect if this is an update
# ============================================================

EXISTING_PROCESS=$(ps | grep -v grep | grep publish_metrics.sh)
IS_UPDATE=0

if [ -f /usr/data/publish_metrics.sh ]; then
    echo "Existing installation detected"
    IS_UPDATE=1
    
    if [ -n "$EXISTING_PROCESS" ]; then
        echo "Stopping running process..."
        killall publish_metrics.sh 2>/dev/null
        sleep 1
        echo "✓ Process stopped"
    fi
else
    echo "New installation"
fi

echo ""

# ============================================================
# CONFIGURATION - MODIFY THESE VALUES
# ============================================================
HA_URL="http://192.168.1.100:8123"
HA_TOKEN="your_long_lived_access_token_here"
MQTT_TOPIC_PREFIX="lghombot"
INTERVAL=300  # 5 minutes

echo "Configuration:"
echo "  Home Assistant URL: $HA_URL"
echo "  MQTT Topic Prefix: $MQTT_TOPIC_PREFIX"
echo "  Interval: $INTERVAL seconds"
echo ""

# ============================================================
# Create the monitoring script
# ============================================================

echo "Creating /usr/data/publish_metrics.sh..."

cat > /usr/data/publish_metrics.sh << 'SCRIPT_END'
#!/bin/sh
# Monitoring LG Hombot vers Home Assistant

# ===== CONFIGURATION =====
HA_URL="%%HA_URL%%"
HA_TOKEN="%%HA_TOKEN%%"
MQTT_TOPIC_PREFIX="%%MQTT_TOPIC_PREFIX%%"
INTERVAL=%%INTERVAL%%

publish_metric() {
    local topic=$1
    local payload=$2
    local full_topic="$MQTT_TOPIC_PREFIX/$HOSTNAME/$topic"
    
    local json_payload="{\"topic\":\"$full_topic\",\"payload\":\"$payload\"}"
    local content_length=${#json_payload}
    
    # Use printf and pipe to nc (netcat) or create temp file for wget
    # Extract host and port from HA_URL
    local ha_host=$(echo $HA_URL | sed 's|http://||' | sed 's|https://||' | cut -d: -f1)
    local ha_port=$(echo $HA_URL | sed 's|http://||' | sed 's|https://||' | cut -d: -f2 | cut -d/ -f1)
    [ -z "$ha_port" ] && ha_port=8123
    
    # Create HTTP POST request manually
    (
        printf "POST /api/services/mqtt/publish HTTP/1.1\r\n"
        printf "Host: $ha_host:$ha_port\r\n"
        printf "Authorization: Bearer $HA_TOKEN\r\n"
        printf "Content-Type: application/json\r\n"
        printf "Content-Length: $content_length\r\n"
        printf "\r\n"
        printf "$json_payload"
    ) | nc $ha_host $ha_port > /dev/null 2>&1
}

while true; do
    # ---------- System information ----------
    HOSTNAME=$(cat /usr/data/nickname.dat 2>/dev/null || echo "unknown")
    MODEL=$(cat /usr/rcfg/Name.dat 2>/dev/null || echo "Unknown Model")
    VERSION=$(grep 'VER_MAINSW' /usr/data/blackbox/cleaningrecord.stc 2>/dev/null | sed 's/.*value="\([^"]*\)".*/\1/')
    [ -z "$VERSION" ] && VERSION="unknown"
    TARGET_PLATFORM=$(grep "Hardware" /proc/cpuinfo | cut -d':' -f2 | sed 's/^ //')
    ARCHITECTURE=$(grep "Processor" /proc/cpuinfo | cut -d':' -f2 | sed 's/^ //')
    UPTIME=$(cat /proc/uptime | cut -d'.' -f1)
    
    publish_metric "system/hostname"        "$HOSTNAME"
    publish_metric "system/model"           "$MODEL"
    publish_metric "system/target_platform" "$TARGET_PLATFORM"
    publish_metric "system/architecture"    "$ARCHITECTURE"
    publish_metric "system/version"         "$VERSION"
    publish_metric "system/uptime"          "$UPTIME"
    
    # ---------- CPU ----------
    LOAD_AVG=$(awk '{print $1","$2","$3}' /proc/loadavg)
    publish_metric "cpu/load" "load:$LOAD_AVG"
    
    LOAD_1MIN=$(awk '{print $1}' /proc/loadavg)
    CPU_LOAD_PERCENT=$(awk -v load="$LOAD_1MIN" 'BEGIN {printf "%.0f", load * 100}')
    publish_metric "cpu/load_percent" "value:$CPU_LOAD_PERCENT"
    
    # ---------- Memory ----------
    MEMORY_FREE=$(awk '/MemFree/  {print $2}' /proc/meminfo)
    MEMORY_CACHED=$(awk '/^Cached:/ {print $2}' /proc/meminfo)
    MEMORY_USED=$(awk '/MemTotal/ {total=$2} /MemFree/ {free=$2} /Buffers/ {buffers=$2} /^Cached:/ {cached=$2} END {print total-free-buffers-cached}' /proc/meminfo)
    MEMORY_TOTAL=$((MEMORY_USED + MEMORY_CACHED + MEMORY_FREE))
    
    if [ $MEMORY_TOTAL -gt 0 ]; then
        MEMORY_USAGE_PERCENT=$((100 * (MEMORY_USED + MEMORY_CACHED) / MEMORY_TOTAL))
    else
        MEMORY_USAGE_PERCENT=0
    fi
    
    publish_metric "memory/memory-free"          "value:$MEMORY_FREE"
    publish_metric "memory/memory-cached"        "value:$MEMORY_CACHED"
    publish_metric "memory/memory-used"          "value:$MEMORY_USED"
    publish_metric "memory/memory-usage-percent" "value:$MEMORY_USAGE_PERCENT"
    
    # ---------- Disk (/usr/data) ----------
    DISK_STATS=$(df -k /usr/data | awk 'NR==2 {print $2, $3, $4}')
    DISK_TOTAL=$(echo $DISK_STATS | awk '{print $1}')
    DISK_USED=$(echo $DISK_STATS  | awk '{print $2}')
    DISK_FREE=$(echo $DISK_STATS  | awk '{print $3}')
    DISK_PERCENT=$([ $DISK_TOTAL -gt 0 ] && echo $((100 * DISK_USED / DISK_TOTAL)) || echo 0)
    
    publish_metric "disk/total"   "value:$DISK_TOTAL"
    publish_metric "disk/used"    "value:$DISK_USED"
    publish_metric "disk/free"    "value:$DISK_FREE"
    publish_metric "disk/percent" "value:$DISK_PERCENT"
    
    # ---------- Tmpfs (/tmp) ----------
    TMP_STATS=$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $2, $3, $4}')
    if [ -n "$TMP_STATS" ]; then
        TMP_TOTAL=$(echo $TMP_STATS | awk '{print $1}')
        TMP_USED=$(echo $TMP_STATS  | awk '{print $2}')
        TMP_FREE=$(echo $TMP_STATS  | awk '{print $3}')
        TMP_PERCENT=$([ $TMP_TOTAL -gt 0 ] && echo $((100 * TMP_USED / TMP_TOTAL)) || echo 0)
        
        publish_metric "disk_tmp/total"   "value:$TMP_TOTAL"
        publish_metric "disk_tmp/used"    "value:$TMP_USED"
        publish_metric "disk_tmp/free"    "value:$TMP_FREE"
        publish_metric "disk_tmp/percent" "value:$TMP_PERCENT"
    fi
    
    # ---------- Network interfaces ----------
    for INTERFACE in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
        if [ -d "/sys/class/net/$INTERFACE/statistics" ]; then
            RX_BYTES=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
            TX_BYTES=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)
            RX_PACKETS=$(cat /sys/class/net/$INTERFACE/statistics/rx_packets 2>/dev/null || echo 0)
            TX_PACKETS=$(cat /sys/class/net/$INTERFACE/statistics/tx_packets 2>/dev/null || echo 0)
            RX_DROPPED=$(cat /sys/class/net/$INTERFACE/statistics/rx_dropped 2>/dev/null || echo 0)
            TX_DROPPED=$(cat /sys/class/net/$INTERFACE/statistics/tx_dropped 2>/dev/null || echo 0)
            RX_ERRORS=$(cat /sys/class/net/$INTERFACE/statistics/rx_errors 2>/dev/null || echo 0)
            TX_ERRORS=$(cat /sys/class/net/$INTERFACE/statistics/tx_errors 2>/dev/null || echo 0)
            
            publish_metric "interface-$INTERFACE/if_octets"  "rx:$RX_BYTES,tx:$TX_BYTES"
            publish_metric "interface-$INTERFACE/if_packets" "rx:$RX_PACKETS,tx:$TX_PACKETS"
            publish_metric "interface-$INTERFACE/if_dropped" "rx:$RX_DROPPED,tx:$TX_DROPPED"
            publish_metric "interface-$INTERFACE/if_errors"  "rx:$RX_ERRORS,tx:$TX_ERRORS"
        fi
    done
    
    sleep $INTERVAL
done
SCRIPT_END

# Replace placeholders with actual values
sed -i "s|%%HA_URL%%|$HA_URL|g" /usr/data/publish_metrics.sh
sed -i "s|%%HA_TOKEN%%|$HA_TOKEN|g" /usr/data/publish_metrics.sh
sed -i "s|%%MQTT_TOPIC_PREFIX%%|$MQTT_TOPIC_PREFIX|g" /usr/data/publish_metrics.sh
sed -i "s|%%INTERVAL%%|$INTERVAL|g" /usr/data/publish_metrics.sh

chmod +x /usr/data/publish_metrics.sh

echo "✓ Monitoring script created"

# ============================================================
# Add to startup script (skip if update)
# ============================================================

if [ $IS_UPDATE -eq 1 ]; then
    echo ""
    echo "Update mode: skipping startup script modification"
else
    echo ""
    echo "Configuring automatic startup..."

    # Use /usr/etc/rc.local (writable location)
    echo "Checking /usr/etc/rc.local..."

    if [ ! -f /usr/etc/rc.local ]; then
        echo "✗ /usr/etc/rc.local does not exist"
        echo ""
        echo "MANUAL STEP REQUIRED:"
        echo "Create /usr/etc/rc.local or add this line to your startup script:"
        echo "/usr/data/publish_metrics.sh > /dev/null 2>&1 &"
        echo ""
    else
        # Backup existing rc.local if it doesn't contain our script
        if ! grep -q "publish_metrics.sh" /usr/etc/rc.local 2>/dev/null; then
            echo "Creating backup: /usr/etc/rc.local.bak"
            cp /usr/etc/rc.local /usr/etc/rc.local.bak
        fi
        
        if grep -q "publish_metrics.sh" /usr/etc/rc.local 2>/dev/null; then
            echo "⚠ Entry already exists in /usr/etc/rc.local, skipping"
        else
            # Insert before the last 'exit 0' line if it exists
            if grep -q "^exit 0" /usr/etc/rc.local; then
                # Insert before exit 0
                sed -i '/^exit 0/i \
# Monitoring système vers Home Assistant\
/usr/data/publish_metrics.sh > /dev/null 2>\&1 \&\
' /usr/etc/rc.local
            else
                # No exit 0, append at end
                cat >> /usr/etc/rc.local << 'USR_RC_END'

# Monitoring système vers Home Assistant
/usr/data/publish_metrics.sh > /dev/null 2>&1 &
USR_RC_END
            fi
            echo "✓ Added to /usr/etc/rc.local"
        fi
    fi
fi

# ============================================================
# Start the monitoring script
# ============================================================

echo ""
echo "Starting monitoring script..."

# Kill any remaining instance
killall publish_metrics.sh 2>/dev/null

# Start new instance
/usr/data/publish_metrics.sh &

sleep 2

if ps | grep -v grep | grep publish_metrics.sh > /dev/null; then
    echo "✓ Monitoring script is running"
    echo ""
    echo "========================================="
    if [ $IS_UPDATE -eq 1 ]; then
        echo "Update complete!"
    else
        echo "Installation complete!"
    fi
    echo "========================================="
    echo ""
    echo "The script will:"
    echo "  - Send metrics every $INTERVAL seconds"
    echo "  - Publish to: $MQTT_TOPIC_PREFIX/<hostname>/*"
    if [ $IS_UPDATE -eq 0 ]; then
        echo "  - Start automatically on boot"
    fi
    echo ""
    echo "To check status: ps | grep publish_metrics.sh"
    echo "To stop: killall publish_metrics.sh"
    echo "To restart: killall publish_metrics.sh && /usr/data/publish_metrics.sh &"
    echo ""
else
    echo "✗ Failed to start monitoring script"
    echo "Check logs or run manually: /usr/data/publish_metrics.sh"
    exit 1
fi
