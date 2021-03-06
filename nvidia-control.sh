#!/bin/bash

<<LICENSE
    Copyright (C) 2017  kevinlekiller
    
    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.
    
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    
    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
    https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html
LICENSE

# Some features of this script require the nvidia xorg setting "coolbits" to have a certain value, 28 should be enough to cover all
# the features in this script, you can read more about "coolbits" in the Nvidia driver README.

# You can set most of these settings from the command line, like this for example : GPUID=1 POWER=60 INTERVAL=3.0 ./nvidia-control.sh
# To make a value empty, set it like this for example: POWER=${POWER:-}
# To set a negative number, set it like this for example: GCLOCK=${GCLOCK:--30}
# nvidia-smi require root access for some commands, to bypass this you can make nvidia-smi not require your password:
# sudo echo "$USER ALL = NOPASSWD: /usr/bin/nvidia-smi" >> /etc/sudoers

# Which GPU to use. find with nvidia-smi -L
GPUID=${GPUID:-0}

# Set the GPU in its highest P-State. Leave empty to disable.
POWERMIZER=${POWERMIZER:-}

# Set the power limit of the GPU. Leave empty to disable.
POWER=${POWER:-}

# Set the GPU clock speed offset in MHz (can be a negative number). Leave empty to disable.
# For example, if your GPU is 1000MHz and you set this to 50, your GPU will be 1050MHz.
GCLOCK=${GCLOCK:-}

# Set the memory clock speed offset in MHz (can be a negative number). Leave empty to disable.
# For example, if your memory is 2000MHz and you set this to -100, your memory will be 1900MHz.
MCLOCK=${MCLOCK:-}

# Which P-State to work on for the GPU / memory clock speed offset, 3 is the highest on modern Nvidia GPUs.
# Usually only the highest P-State can be changed. You can find the perf levels for your card with: nvidia-settings -q GPUPerfModes
PSTATE=${PSTATE:-3}

# How many seconds to wait before checking temps / setting fan speeds. Lower values mean higher CPU usage. Leave empty to disable fan control.
INTERVAL=${INTERVAL:-5.0}

# Show the temp to speed map then exit. Leave empty to disable.
SHOWMAP=${SHOWMAP:-}

# Show the current speed / temp. Leave empty to disable.
SHOWCURRENT=${SHOWCURRENT:-}

# Set the LED brightness in percentage (assuming your card has LED's). Can be a number between 0 and 100. Leave empty to keep the default brightness.
LEDPERCENT=${LEDPERCENT:-}

# Set fan speed to this speed if GPU temperature under TEMP[0]
MINSPEED=0

# What fan speed to set at what temperature, for example set the fan speed at 25% when GPU temp is 50 degrees.
# All other values are calculated on the fly, pass the SHOWMAP=true environment variable to show the calculated values.
TEMP[0]=50
SPEED[0]=25

TEMP[1]=60
SPEED[1]=50

TEMP[2]=70
SPEED[2]=75

TEMP[3]=80
SPEED[3]=100

# This is in case there's some kind of logic flaw in the while loop. Can be left as is.
SAFESPEED=${SPEED[1]}

############################################################################################
declare -A PAIRS
for PAIR in 0:1 1:2 2:3; do
    LOW=$(echo "$PAIR" | cut -d: -f1)
    HIGH=$(echo "$PAIR" | cut -d: -f2)
    TDIFF0=$(bc -l <<< "$((${SPEED[$HIGH]} - ${SPEED[$LOW]})) / $((${TEMP[$HIGH]} - ${TEMP[$LOW]}))")
    CURSPEED=${SPEED[$LOW]}
    for i in $(seq ${TEMP[$LOW]} ${TEMP[$HIGH]}); do
        RNDSPEED=$(echo $CURSPEED | awk '{print int($1+0.5)}')
        if [[ $RNDSPEED -le ${SPEED[$LOW]} ]]; then
            PAIRS[$i]=${SPEED[$LOW]}
        elif [[ $RNDSPEED -ge ${SPEED[$HIGH]} ]]; then
            PAIRS[$i]=${SPEED[$HIGH]}
        else
            PAIRS[$i]=$RNDSPEED
        fi
        CURSPEED=$(bc -l <<< "$TDIFF0 + $CURSPEED")
    done
done

if [[ $SHOWMAP ]]; then
    echo "TEMP SPEED"
    for i in "${!PAIRS[@]}"; do
        echo "$i   ${PAIRS[$i]}"
    done | sort -n
    exit
fi

trap cleanup SIGHUP SIGINT SIGQUIT SIGFPE SIGKILL SIGTERM
function cleanup() {
    echo "Exiting, cleaning up."
    if [[ $CHANGEDPM ]]; then
        echo "Disabling persistance mode. (Requires root)"
        sudo nvidia-smi --persistence-mode=0 --id="$GPUID" 1> /dev/null
        nvidia-smi > /dev/null
    fi
    if [[ $CPDRAW ]]; then
        echo "Reverting power limit to $CPDRAW. (Requires root)"
        sudo nvidia-smi --id="$GPUID" -pl $CPDRAW 1> /dev/null
    fi
    if [[ $CHANGEDFS ]]; then
        echo "Enabling automatic fan control."
        nvidia-settings --assign [gpu:$GPUID]/GPUFanControlState=0 1> /dev/null
    fi
    if [[ $POWERMIZER ]]; then
        echo "Setting automatic P-State control."
        nvidia-settings --assign [gpu:$GPUID]/GPUPowerMizerMode=1 1> /dev/null
    fi
    if [[ -z $1 ]]; then
        exit
    fi
    exit $1
}

if [[ $POWER ]]; then
    CHANGEDPM=1
    echo "Enabling persistence mode for gpu $GPUID. (Requires root)"
    sudo nvidia-smi --persistence-mode=1 --id="$GPUID" 1> /dev/null
    PDRAW=$(nvidia-smi --id="$GPUID" -q -d POWER)
    if [[ -z $PDRAW ]]; then
        echo "Error probing Nvidia power limit!"
        cleanup 1
    fi
    MIPDRAW=$(echo "$PDRAW" | grep "Min Power Limit" | cut -d: -f2 | grep -Po "^\s*\d+" | xargs)
    MAPDRAW=$(echo "$PDRAW" | grep "Max Power Limit" | cut -d: -f2 | grep -Po "^\s*\d+" | xargs)
    CPDRAW=$(echo "$PDRAW" | grep "^\s*Power Limit" | cut -d: -f2 | grep -Po "^\s*\d+" | xargs)
    PDRAW=$(echo "$PDRAW" | grep "Default Power Limit" | cut -d: -f2 | grep -Po "^\s*\d+" | xargs)
    if [[ -z $MIPDRAW ]] || [[ -z $MAPDRAW ]] || [[ -z $PDRAW ]] || [[ -z $CPDRAW ]]; then
        echo "Error parsing power draw limits from Nvidia GPU!"
        cleanup 1
    elif [[ $POWER -lt 1 ]]; then
        echo "Power limit is lower than 1%, setting to 1%"
        POWER=1
    fi
    WPDRAW=$(($(($((PDRAW * 10)) * POWER)) / 1000))
    if [[ $WPDRAW -gt $MAPDRAW ]]; then
        echo "The Nvidia driver allows a maximum of $MAPDRAW watts for this GPU. Setting to maximum."
        WPDRAW=$MAPDRAW
    elif [[ $WPDRAW -lt $MIPDRAW ]]; then
        echo "The Nvidia driver allows a minimum of $MIPDRAW watts for this GPU. Setting to minimum."
        WPDRAW=$MIPDRAW
    fi
    echo "Setting power limit to ${POWER}% (${WPDRAW} watts). (Requires root)"
    sudo nvidia-smi --id="$GPUID" -pl $WPDRAW 1> /dev/null
fi

if [[ $POWERMIZER ]]; then
    echo "Setting GPU to highest P-State."
    nvidia-settings --assign [gpu:$GPUID]/GPUPowerMizerMode=0 1> /dev/null
fi

if [[ $GCLOCK ]]; then
    echo "Setting GPU clock offset to $GCLOCK."
    nvidia-settings --assign [gpu:$GPUID]/GPUGraphicsClockOffset[$PSTATE]=$GCLOCK 1> /dev/null
fi

if [[ $MCLOCK ]]; then
    echo "Setting GPU memory offset to $MCLOCK."
    nvidia-settings --assign [gpu:$GPUID]/GPUMemoryTransferRateOffset[$PSTATE]=$MCLOCK 1> /dev/null
fi

if [[ $LEDPERCENT ]] && [[ $LEDPERCENT -ge 0 ]] && [[ $LEDPERCENT -le 100 ]]; then
    echo "Setting LED brightness to $LEDPERCENT percent."
    nvidia-settings --assign [gpu:$GPUID]/GPULogoBrightness=$LEDPERCENT 1> /dev/null
fi

if [[ $INTERVAL ]]; then
    CHANGEDFS=1
    while [[ true ]]; do
        CTEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader --id=$GPUID)
        if [[ $CTEMP -lt ${TEMP[0]} ]]; then
            SPEED=$MINSPEED
        elif [[ $CTEMP -ge ${TEMP[3]} ]]; then
            SPEED=${SPEED[3]}
        elif [[ ! -z ${PAIRS[$CTEMP]} ]]; then
            SPEED=${PAIRS[$CTEMP]}
        else
            SPEED=$SAFESPEED
        fi
        if [[ $SHOWCURRENT ]]; then
            echo -ne "\033[2KCurrent Temp: $CTEMP Speed: $SPEED\r"
        fi
        nvidia-settings --assign [gpu:$GPUID]/GPUFanControlState=1 --assign [fan:$GPUID]/GPUTargetFanSpeed=$SPEED 1> /dev/null
        sleep $INTERVAL
    done
    if [[ $SHOWCURRENT ]]; then
        echo
    fi
fi
