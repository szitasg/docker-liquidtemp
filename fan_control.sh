#!/bin/bash

exec >/proc/1/fd/1 2>&1

# Load the environment variables
set -a
source /usr/local/bin/env_file
set +a

#set -x

# Log
echo "$(date): Script executed"

# Make that liquidctl is initialized
#liquidctl initialize all

# List of excluded drives
# EXCLUDED_DRIVES="/dev/sda|/dev/sdb|/dev/nvme1n1|/dev/nvme0n1"
EXCLUDED_DRIVES=$(echo "$EXCLUDED_DRIVES_ENV" | tr ',' '|')

# Set the thresholds for each fan speed level
# THRESHOLDS=(20 25 30 35 40 45)
if [ -z "$THRESHOLDS_ENV" ]; then
    THRESHOLDS=(20 25 30 35 40 45) # Default thresholds
    echo "Missing Thresholds - Setting to 20 25 30 35 40 45"
else
    THRESHOLDS=(${THRESHOLDS_ENV//,/ })
fi

# Set the corresponding fan speed levels
# FAN_SPEEDS=(20 30 40 50 60 100)
if [ -z "$FAN_SPEEDS_ENV" ]; then
    FAN_SPEEDS=(20 30 40 50 60 100) # Default fan speeds
    echo "Missing Fan Speeds - Setting to 20 30 40 50 60 100"
else
    FAN_SPEEDS=(${FAN_SPEEDS_ENV//,/ })
fi

# Set the number of drives
ALL_DRIVES=$(ls /dev/sd* | grep -v '[0-9]$' && ls /dev/nvme* | grep -v 'n[0-9]')
DRIVES=$(echo $ALL_DRIVES | tr " " "\n" | grep -vE "$EXCLUDED_DRIVES")
DRIVE_COUNT=$(echo $DRIVES | tr " " "\n" | wc -l)

echo "All drives: $ALL_DRIVES"
echo "Checked drives ($DRIVE_COUNT): $DRIVES"

# Sum of temperatures of all drives
STANDBY_DRIVE_COUNT=0
TEMP_SUM=0

# Get the temperatures of all drives and calculate the sum
for drive in ${DRIVES}; do
    if [[ "$drive" == *"nvme"* ]]; then
        TEMP=$(smartctl -A "$drive" | awk '/Temperature:/ {print $2}')
        echo "$drive temperature:..... $TEMP °C."
    else
        TEMP=$(smartctl -A "$drive" | awk '/Temperature_Celsius/ {print $10}')
        echo "$drive temperature:....... $TEMP °C."
    fi
    if [[ $TEMP =~ ^[0-9]+$ ]]; then
        TEMP_SUM=$((TEMP_SUM + TEMP))
    else
        echo "Failed to get temperature for drive $drive."
    fi
done

#echo "Number of spun down drives:. $STANDBY_DRIVE_COUNT"

# Calculate the average temperature
DRIVE_COUNT=$((DRIVE_COUNT - STANDBY_DRIVE_COUNT)) # Subtract the number of drives in standby mode
if [ $DRIVE_COUNT -gt 0 ]; then
    AVG_TEMP=$((TEMP_SUM / DRIVE_COUNT))
else
    AVG_TEMP=0
fi

echo "Average temperature:........ $AVG_TEMP °C"

# Find the highest threshold that is less than or equal to the average temperature
FAN_SPEED=${FAN_SPEEDS[0]} # Set the fan speed to the lowest value by default

for i in "${!THRESHOLDS[@]}"; do
    if ((AVG_TEMP >= THRESHOLDS[i])); then
        FAN_SPEED=${FAN_SPEEDS[i]}
    else
        break # Exit the loop if the threshold condition is not met
    fi
done

# Set the fan quantity
if [ -z "$FAN_LIST_ENV" ]; then
    FAN_LIST="1"
    echo "Missing Fan List - Setting to 1"
else
    FAN_LIST=${FAN_LIST_ENV//,/ } # Specify the number of fans
fi

# Set the fan speed for all fans
for fan in $FAN_LIST; do
    desired_speed=$FAN_SPEED
    current_speed=$(cat /SPEED_$fan)
    fan_status=$(liquidctl status | awk -F '  ' '/Fan '"$fan"' speed/ {print $0}')
    FAN_RPM=$(echo "$fan_status" | awk '{print $(NF-1)}')

    if [ "$current_speed" == "$desired_speed" ]; then
        echo "Fan speed of fan$fan already set to $desired_speed %."
        continue # Skip fan speed change
    fi

    if [ -z "$desired_speed" ] || [ "$desired_speed" -eq 0 ]; then
        echo "Fan speed not set for fan$fan or set to 0. Setting to 50..."
        liquidctl set fan$fan speed 50
    else
        echo "Setting fan$fan speed to $desired_speed. RPM: $FAN_RPM."
        liquidctl set fan$fan speed $desired_speed || {
            echo "An error occurred while setting the fan speed. Setting fan$fan speed to 50."
            liquidctl set fan$fan speed 50
        }

        # Check if fan RPM is zero
        # FAN_RPM=$(liquidctl status | awk -F '  ' '/Fan '"$fan"' speed/ {print $2}' | tr -d ' rpm')
        if [[ $FAN_RPM =~ ^[0-9]+$ ]] && ((FAN_RPM <= 0)); then
            echo "Fan$fan RPM is zero. Restarting liquidctl... This might not work, recommend checking physical connections."
            pkill liquidctl
            sleep 2
            liquidctl set fan$fan speed $desired_speed
        fi
    fi
    echo $desired_speed > /SPEED_$fan
done

echo
