#!/bin/bash
# Copyright 2018 WSO2 Inc. (http://wso2.org)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ----------------------------------------------------------------------------
# Create a summary report from JMeter results
# ----------------------------------------------------------------------------

script_dir=$(dirname "$0")
# Application Name to be used in column headers
application_name=""
print_column_names=false
# Prefix of files
file_prefix=""
# Results directory
default_results_dir="${script_dir}/results"
results_dir="$default_results_dir"
# GCViewer Jar file to analyze GC logs
gcviewer_jar_path=""
# JMeter Servers
# If jmeter_servers = 1, only client was used. If jmeter_servers > 1, remote JMeter servers were used.
default_jmeter_servers=1
jmeter_servers=$default_jmeter_servers
# Use warmup results
use_warmup=false
# Include GC statistics and load averages for other servers
include_all=false

function usage() {
    echo ""
    echo "Usage: "
    echo "$0 -n <application_name> [-x] [-p <file_prefix>] [-g <gcviewer_jar_path>] [-d <results_dir>]"
    echo "   [-j <jmeter_servers>] [-w] [-i] [-h]"
    echo ""
    echo "-n: Name of the application to be used in column headers."
    echo "-x: Print column names and exit."
    echo "-p: Prefix of the files to get metrics (Load Average, GC, etc)."
    echo "-g: Path of GCViewer Jar file, which will be used to analyze GC logs."
    echo "-d: Results directory. Default $default_results_dir."
    echo "-j: Number of JMeter servers. If n=1, only client was used. If n > 1, remote JMeter servers were used. Default $default_jmeter_servers."
    echo "-w: Use warmup results instead of measurement results."
    echo "-i: Include GC statistics and load averages for other servers."
    echo "-h: Display this help and exit."
    echo ""
}

while getopts "n:xp:g:d:j:wih" opts; do
    case $opts in
    n)
        application_name=${OPTARG}
        ;;
    x)
        print_column_names=true
        ;;
    p)
        file_prefix=${OPTARG}
        ;;
    g)
        gcviewer_jar_path=${OPTARG}
        ;;
    d)
        results_dir=${OPTARG}
        ;;
    j)
        jmeter_servers=${OPTARG}
        ;;
    w)
        use_warmup=true
        ;;
    i)
        include_all=true
        ;;
    h)
        usage
        exit 0
        ;;
    \?)
        usage
        exit 1
        ;;
    esac
done

# Validate options
if [[ -z $application_name ]]; then
    echo "Please specify the application name."
    exit 1
fi

if [[ -z $jmeter_servers ]]; then
    echo "Please specify the number of JMeter servers."
    exit 1
fi

function add_gc_headers() {
    headers+=("$1 GC Throughput (%)")
    headers+=("$1 Memory Footprint (M)")
    headers+=("Average of $1 Memory Footprint After Full GC (M)")
    headers+=("Standard Deviation of $1 Memory Footprint After Full GC (M)")
}

function add_loadavg_headers() {
    headers+=("$1 Load Average - Last 1 minute")
    headers+=("$1 Load Average - Last 5 minutes")
    headers+=("$1 Load Average - Last 15 minutes")
}

declare -ag headers
headers+=("Scenario Name")
headers+=("Heap Size")
headers+=("Concurrent Users")
headers+=("Message Size (Bytes)")
headers+=("Back-end Service Delay (ms)")
headers+=("# Samples")
headers+=("Error Count")
headers+=("Error %")
headers+=("Throughput (Requests/sec)")
headers+=("Average Response Time (ms)")
headers+=("Standard Deviation of Response Time (ms)")
headers+=("Minimum Response Time (ms)")
headers+=("Maximum Response Time (ms)")
headers+=("75th Percentile of Response Time (ms)")
headers+=("90th Percentile of Response Time (ms)")
headers+=("95th Percentile of Response Time (ms)")
headers+=("98th Percentile of Response Time (ms)")
headers+=("99th Percentile of Response Time (ms)")
headers+=("99.9th Percentile of Response Time (ms)")
headers+=("Received (KB/sec)")
headers+=("Sent (KB/sec)")
add_gc_headers "${application_name}"
if [ "$include_all" = true ]; then
    add_gc_headers "Netty Service"
    add_gc_headers "JMeter Client"
    if [ $jmeter_servers -gt 1 ]; then
        for ((c = 1; c <= $jmeter_servers; c++)); do
            add_gc_headers "JMeter Server $c"
        done
    fi
fi
add_loadavg_headers "${application_name}"
if [ "$include_all" = true ]; then
    add_loadavg_headers "Netty Service"
    add_loadavg_headers "JMeter Client"
    if [ $jmeter_servers -gt 1 ]; then
        for ((c = 1; c <= $jmeter_servers; c++)); do
            add_loadavg_headers "JMeter Server $c"
        done
    fi
fi

if [ "$print_column_names" = true ]; then
    for ((i = 0; i < ${#headers[@]}; i++)); do
        echo "${headers[$i]}"
    done
    exit 0;
fi

if [[ -z $file_prefix ]]; then
    echo "Please specify the prefix of the files."
    exit 1
fi

if [[ ! -d $results_dir ]]; then
    echo "Please specify the results directory."
    exit 1
fi

if [[ ! -f $gcviewer_jar_path ]]; then
    echo "Please specify the path to GCViewer JAR file."
    exit 1
fi

# Output file name
filename="summary.csv"

if [[ -f $filename ]]; then
    echo "$filename already exists"
    exit 1
fi

declare -A scenario_display_names

# Check test-metadata.json file
if [[ -f ${results_dir}/test-metadata.json ]]; then
    while IFS='=' read -r key value; do
        scenario_display_names["$key"]="$value"
    done < <(jq -r '.test_scenarios[] | "\(.name)=\(.display_name)"' ${results_dir}/test-metadata.json)
else
    echo "WARNING: Could not find test metadata."
fi

header_row=""
for ((i = 0; i < ${#headers[@]}; i++)); do
    if [ $i -gt 0 ]; then
        header_row+=","
    fi
    header_row+="${headers[$i]}"
done

echo -ne "${header_row}\r\n" >$filename

function write_column() {
    local data_file="$1"
    local name="$2"
    echo -n "," >>$filename
    echo -n "$(jq -r ".$name" "$data_file")" >>$filename
}

function get_value_from_gc_summary() {
    echo $(grep -m 1 $2\; $1 | sed -r 's/.*\;(.*)\;.*/\1/' | sed 's/,//g')
}

function add_gc_summary_details() {
    local gc_log_file="${current_dir}/$1_gc.log"
    if [[ -f $gc_log_file ]]; then
        local gc_summary_file="/tmp/gc.txt"
        echo "Reading $gc_log_file"
        java -Xms128m -Xmx128m -jar $gcviewer_jar_path $gc_log_file $gc_summary_file -t SUMMARY &>/dev/null
        columns+=("$(get_value_from_gc_summary $gc_summary_file throughput)")
        columns+=("$(get_value_from_gc_summary $gc_summary_file footprint)")
        columns+=("$(get_value_from_gc_summary $gc_summary_file avgfootprintAfterFullGC)")
        columns+=("$(get_value_from_gc_summary $gc_summary_file avgfootprintAfterFullGCσ)")
    else
        echo "WARNING: File missing! $gc_log_file"
        columns+=("N/A" "N/A" "N/A" "N/A")
    fi
}

function add_loadavg_details() {
    local loadavg_file="${current_dir}/$1_loadavg.txt"
    if [[ -f $loadavg_file ]]; then
        echo "Reading $loadavg_file"
        local loadavg_values=$(tail -2 $loadavg_file | head -1)
        declare -a loadavg_array=($loadavg_values)
        columns+=("${loadavg_array[3]}")
        columns+=("${loadavg_array[4]}")
        columns+=("${loadavg_array[5]}")
    else
        echo "WARNING: File missing! $loadavg_file"
        columns+=("N/A" "N/A" "N/A")
    fi
}

# Results are in following directory structure:
# results/${scenario_name}/${heap}_heap/${total_users}_users/${msize}B/${sleep_time}ms_sleep

for scenario_dir in $(find ${results_dir} -maxdepth 1 -type d | sort -V); do
    for heap_size_dir in $(find ${scenario_dir} -maxdepth 1 -type d -name '*_heap' | sort -V); do
        for user_dir in $(find ${heap_size_dir} -maxdepth 1 -type d -name '*_users' | sort -V); do
            for message_size_dir in $(find ${user_dir} -maxdepth 1 -type d -name '*B' | sort -V); do
                for sleep_time_dir in $(find ${message_size_dir} -maxdepth 1 -type d -name '*ms_sleep' | sort -V); do
                    current_dir="${sleep_time_dir}"
                    echo "Current directory: $current_dir."
                    data_file="${current_dir}/results-measurement-summary.json"
                    if [[ $use_warmup == true ]]; then
                        data_file="${current_dir}/results-warmup-summary.json"
                    fi
                    if [[ ! -f $data_file ]]; then
                        echo "WARN: Data file not found: $data_file"
                        continue
                    fi

                    echo "Getting data from $data_file"
                    scenario_name="$(echo $scenario_dir | sed -nE 's/.*.\/(.*)/\1/p')"
                    heap_size=$(echo $heap_size_dir | sed -nE 's/.*.\/([0-9]+[a-zA-Z])_heap.*/\1/p')
                    concurrent_users=$(echo $user_dir | sed -nE 's/.*\/([0-9]+)_users.*/\1/p')
                    message_size=$(echo $message_size_dir | sed -nE 's/.*\/([0-9]+)B.*/\1/p')
                    sleep_time=$(echo $sleep_time_dir | sed -nE 's/.*\/([0-9]+)ms_sleep.*/\1/p')

                    if [[ -z $sleep_time ]]; then
                        sleep_time="N/A"
                    fi

                    declare -A summary_results
                    while IFS="=" read -r key value; do
                        summary_results[$key]="$value"
                    done < <(jq -r "to_entries|map(\"\(.key)=\(.value)\")|.[]" $data_file)

                    declare -ag columns=()
                    columns+=("${scenario_display_names[$scenario_name]=$scenario_name}")
                    columns+=("$heap_size")
                    columns+=("$concurrent_users")
                    columns+=("$message_size")
                    columns+=("$sleep_time")
                    columns+=("${summary_results[samples]}")
                    columns+=("${summary_results[errors]}")
                    columns+=("${summary_results[errorPercentage]}")
                    columns+=("${summary_results[throughput]}")
                    columns+=("${summary_results[mean]}")
                    columns+=("${summary_results[stddev]}")
                    columns+=("${summary_results[min]}")
                    columns+=("${summary_results[max]}")
                    columns+=("${summary_results[p75]}")
                    columns+=("${summary_results[p90]}")
                    columns+=("${summary_results[p95]}")
                    columns+=("${summary_results[p98]}")
                    columns+=("${summary_results[p99]}")
                    columns+=("${summary_results[p999]}")
                    columns+=("${summary_results[receivedKBytesRate]}")
                    columns+=("${summary_results[sentKBytesRate]}")

                    add_gc_summary_details $file_prefix
                    if [ "$include_all" = true ]; then
                        add_gc_summary_details netty
                        add_gc_summary_details jmeter
                        if [ $jmeter_servers -gt 1 ]; then
                            for ((c = 1; c <= $jmeter_servers; c++)); do
                                add_gc_summary_details jmeter$c
                            done
                        fi
                    fi

                    add_loadavg_details $file_prefix
                    if [ "$include_all" = true ]; then
                        add_loadavg_details netty
                        add_loadavg_details jmeter
                        if [ $jmeter_servers -gt 1 ]; then
                            for ((c = 1; c <= $jmeter_servers; c++)); do
                                add_loadavg_details jmeter$c
                            done
                        fi
                    fi

                    row=""
                    for ((i = 0; i < ${#columns[@]}; i++)); do
                        if [ $i -gt 0 ]; then
                            row+=","
                        fi
                        row+="${columns[$i]}"
                    done

                    echo -ne "${row}\r\n" >>$filename
                done
            done
        done
    done
done
echo "Wrote summary statistics to $filename."
