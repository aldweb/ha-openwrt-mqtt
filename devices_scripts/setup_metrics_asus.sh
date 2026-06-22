#!/bin/sh

# Metrics installation script for ASUS router (Asuswrt-Merlin)
# Sends data to Home Assistant via REST API

echo "=== Configuring metrics for ASUS router ==="

# Check that curl is available
if ! which curl &> /dev/null; then
    echo "Error: curl is not installed. This script requires curl."
    echo "Please install Entware and curl before continuing."
    exit 1
fi

echo "curl is available."

# Create the metrics publishing script
cat > /jffs/scripts/publish_metrics.sh << 'SCRIPT_END'
#!/bin/sh

# Home Assistant configuration
HA_URL="http://<HOME_ASSISTANT_IP>:8123"
HA_TOKEN="<YOUR_HOME_ASSISTANT_TOKEN>"
MQTT_TOPIC_PREFIX="asus"

# Get hostname
HOSTNAME=$(nvram get computer_name 2>/dev/null)
[ -z "$HOSTNAME" ] && HOSTNAME=$(nvram get lan_hostname 2>/dev/null)
[ -z "$HOSTNAME" ] && HOSTNAME=$(hostname 2>/dev/null)
[ -z "$HOSTNAME" ] && HOSTNAME="asus-router"

# Function to publish to Home Assistant via MQTT REST API
publish_metric() {
    local topic=$1
    local payload=$2
    local full_topic="$MQTT_TOPIC_PREFIX/$HOSTNAME/$topic"
    
    curl -s -X POST \
        -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"topic\":\"$full_topic\",\"payload\":\"$payload\"}" \
        "$HA_URL/api/services/mqtt/publish" > /dev/null 2>&1
}

# System information
MODEL=$(nvram get productid)
[ -z "$MODEL" ] && MODEL="Unknown Model"

FIRMWARE=$(nvram get firmver)
BUILD=$(nvram get buildno)
VERSION="${FIRMWARE}.${BUILD}"

UPTIME=$(cat /proc/uptime | cut -d. -f1)

publish_metric "system/hostname" "$HOSTNAME"
publish_metric "system/model" "$MODEL"
publish_metric "system/version" "$VERSION"
publish_metric "system/uptime" "$UPTIME"

# CPU load
LOAD_AVG=$(cat /proc/loadavg | awk '{print $1","$2","$3}')
publish_metric "cpu/load" "load:$LOAD_AVG"

# CPU load percentage
CPU_CORES=$(grep -c "^processor" /proc/cpuinfo)
LOAD_1MIN=$(cat /proc/loadavg | awk '{print $1}')
CPU_LOAD_PERCENT=$(awk -v load="$LOAD_1MIN" -v cores="$CPU_CORES" 'BEGIN {printf "%.0f", (load / cores) * 100}')
publish_metric "cpu/load_percent" "value:$CPU_LOAD_PERCENT"

# Memory usage (in KB)
MEMORY_FREE=$(awk '/MemFree/ {print $2}' /proc/meminfo)
MEMORY_CACHED=$(awk '/Cached/ {print $2}' /proc/meminfo | head -n 1)
MEMORY_BUFFERS=$(awk '/Buffers/ {print $2}' /proc/meminfo)
MEMORY_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEMORY_USED=$((MEMORY_TOTAL - MEMORY_FREE - MEMORY_BUFFERS - MEMORY_CACHED))

# Memory usage percentage
if [ $MEMORY_TOTAL -gt 0 ]; then
    MEMORY_USAGE_PERCENT=$((100 * MEMORY_USED / MEMORY_TOTAL))
else
    MEMORY_USAGE_PERCENT=0
fi

publish_metric "memory/memory-free" "value:$MEMORY_FREE"
publish_metric "memory/memory-cached" "value:$MEMORY_CACHED"
publish_metric "memory/memory-used" "value:$MEMORY_USED"
publish_metric "memory/memory-total" "value:$MEMORY_TOTAL"
publish_metric "memory/memory-usage-percent" "value:$MEMORY_USAGE_PERCENT"

# JFFS disk usage
if [ -d /jffs ]; then
    JFFS_STATS=$(df -k /jffs 2>/dev/null | awk 'NR==2 {print $2, $3, $4}')
    if [ -n "$JFFS_STATS" ]; then
        JFFS_TOTAL=$(echo $JFFS_STATS | awk '{print $1}')
        JFFS_USED=$(echo $JFFS_STATS | awk '{print $2}')
        JFFS_FREE=$(echo $JFFS_STATS | awk '{print $3}')
        
        if [ $JFFS_TOTAL -gt 0 ]; then
            JFFS_PERCENT=$((100 * JFFS_USED / JFFS_TOTAL))
        else
            JFFS_PERCENT=0
        fi
        
        publish_metric "disk/total" "value:$JFFS_TOTAL"
        publish_metric "disk/used" "value:$JFFS_USED"
        publish_metric "disk/free" "value:$JFFS_FREE"
        publish_metric "disk/percent" "value:$JFFS_PERCENT"
    fi
fi

# Tmpfs usage (/tmp)
TMP_STATS=$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $2, $3, $4}')
if [ -n "$TMP_STATS" ]; then
    TMP_TOTAL=$(echo $TMP_STATS | awk '{print $1}')
    TMP_USED=$(echo $TMP_STATS | awk '{print $2}')
    TMP_FREE=$(echo $TMP_STATS | awk '{print $3}')
    
    if [ $TMP_TOTAL -gt 0 ]; then
        TMP_PERCENT=$((100 * TMP_USED / TMP_TOTAL))
    else
        TMP_PERCENT=0
    fi
    
    publish_metric "disk_tmp/total" "value:$TMP_TOTAL"
    publish_metric "disk_tmp/used" "value:$TMP_USED"
    publish_metric "disk_tmp/free" "value:$TMP_FREE"
    publish_metric "disk_tmp/percent" "value:$TMP_PERCENT"
fi

# Connection tracking statistics
if [ -f /proc/net/nf_conntrack ]; then
    CONN_TOTAL=$(wc -l < /proc/net/nf_conntrack)
    publish_metric "conntrack/total" "value:$CONN_TOTAL"
fi

# Network interface statistics
for INTERFACE in $(ls /sys/class/net/ | grep -v lo); do
    # Check that interface exists and is active
    if [ -d "/sys/class/net/$INTERFACE/statistics" ]; then
        RX_BYTES=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
        TX_BYTES=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)
        RX_PACKETS=$(cat /sys/class/net/$INTERFACE/statistics/rx_packets 2>/dev/null || echo 0)
        TX_PACKETS=$(cat /sys/class/net/$INTERFACE/statistics/tx_packets 2>/dev/null || echo 0)
        RX_DROPPED=$(cat /sys/class/net/$INTERFACE/statistics/rx_dropped 2>/dev/null || echo 0)
        TX_DROPPED=$(cat /sys/class/net/$INTERFACE/statistics/tx_dropped 2>/dev/null || echo 0)
        RX_ERRORS=$(cat /sys/class/net/$INTERFACE/statistics/rx_errors 2>/dev/null || echo 0)
        TX_ERRORS=$(cat /sys/class/net/$INTERFACE/statistics/tx_errors 2>/dev/null || echo 0)

        publish_metric "interface-$INTERFACE/if_octets" "rx:$RX_BYTES,tx:$TX_BYTES"
        publish_metric "interface-$INTERFACE/if_packets" "rx:$RX_PACKETS,tx:$TX_PACKETS"
        publish_metric "interface-$INTERFACE/if_dropped" "rx:$RX_DROPPED,tx:$TX_DROPPED"
        publish_metric "interface-$INTERFACE/if_errors" "rx:$RX_ERRORS,tx:$TX_ERRORS"
    fi
done

# CPU temperature (if available on RT-AX86U)
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)
    # Convert from millidegrees to degrees
    CPU_TEMP_C=$((CPU_TEMP / 1000))
    publish_metric "temperature/cpu" "value:$CPU_TEMP_C"
elif [ -f /proc/dmu/temperature ]; then
    # Alternative for some ASUS models
    CPU_TEMP=$(cat /proc/dmu/temperature | grep -oE '[0-9]+' | head -n 1)
    [ -n "$CPU_TEMP" ] && publish_metric "temperature/cpu" "value:$CPU_TEMP"
fi

# Connected WiFi clients
if which wl &> /dev/null; then
    WIFI_2G=$(wl -i eth6 assoclist 2>/dev/null | wc -l)
    WIFI_5G=$(wl -i eth7 assoclist 2>/dev/null | wc -l)
    WIFI_TOTAL=$((WIFI_2G + WIFI_5G))
    
    publish_metric "wifi/clients_2ghz" "value:$WIFI_2G"
    publish_metric "wifi/clients_5ghz" "value:$WIFI_5G"
    publish_metric "wifi/clients_total" "value:$WIFI_TOTAL"
fi

SCRIPT_END

# Make the script executable
chmod +x /jffs/scripts/publish_metrics.sh

echo "Publishing script created: /jffs/scripts/publish_metrics.sh"

# Create or update the cron job
# On ASUS, use the cron service via services-start
if [ ! -f /jffs/scripts/services-start ]; then
    cat > /jffs/scripts/services-start << 'CRON_SCRIPT'
#!/bin/sh

# Add cron job for metrics (every 5 minutes)
cru a PublishMetrics "*/5 * * * * /bin/sh /jffs/scripts/publish_metrics.sh"
CRON_SCRIPT
    chmod +x /jffs/scripts/services-start
    echo "services-start file created."
else
    # Check if the cron job already exists
    if ! grep -q "publish_metrics.sh" /jffs/scripts/services-start; then
        # Add the cron job to the existing file
        echo "" >> /jffs/scripts/services-start
        echo "# Cron job for metrics" >> /jffs/scripts/services-start
        echo "cru a PublishMetrics \"*/5 * * * * /bin/sh /jffs/scripts/publish_metrics.sh\"" >> /jffs/scripts/services-start
        echo "Cron job added to existing services-start file."
    else
        echo "Cron job already present in services-start."
    fi
fi

# Add the cron job immediately (without restart)
cru a PublishMetrics "*/5 * * * * /bin/sh /jffs/scripts/publish_metrics.sh"

echo ""
echo "=== Installation complete ==="
echo ""
echo "IMPORTANT: You must now configure the following parameters"
echo "in the file /jffs/scripts/publish_metrics.sh:"
echo ""
echo "1. Replace <HOME_ASSISTANT_IP> with your Home Assistant IP"
echo "2. Replace <YOUR_HOME_ASSISTANT_TOKEN> with your access token"
echo ""
echo "To get a long-lived access token in Home Assistant:"
echo "  - Go to Profile (bottom left)"
echo "  - Scroll down to 'Long-Lived Access Tokens'"
echo "  - Click 'Create Token'"
echo ""
echo "To edit the file:"
echo "  vi /jffs/scripts/publish_metrics.sh"
echo ""
echo "To test the script manually:"
echo "  /jffs/scripts/publish_metrics.sh"
echo ""
echo "The script will run automatically every 5 minutes."
echo "After next reboot, it will start automatically."
