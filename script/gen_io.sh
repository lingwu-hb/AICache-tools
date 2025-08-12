#!/bin/bash
# 配置颜色输出
INFO='\e[32m[INFO]\e[0m'
ERROR='\e[31m[ERROR]\e[0m'
WARNING='\e[33m[WARNING]\e[0m'

# 示例路径：rawfio/das-bind+ali-dev-3.txt/0317_1905/fio_result.log
# 示例路径：rawfio/no_prefetch+ali-dev-3.txt/0317_1905/fio_result.log
# Source configuration
SCRIPT_DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
source ${SCRIPT_DIR}/config.sh

echo "SCRIPT_DIR: $SCRIPT_DIR"
echo "HOME_PATH: $HOME_PATH"
echo "RESULT_BASE: $RESULT_BASE"
echo "FIO_PATH: $FIO_PATH"
echo "CSV_PATH: $CSV_PATH"
echo "LOG_PATH: $LOG_PATH"

# 确保必要的目录存在
# create_required_dirs

# 获取当前日期和时间（格式：YYYY-MM-DD_HH-MM-SS）
timestamp=$(date +%Y-%m-%d_%H-%M-%S)

# 获取当前日期（格式：YYYY-MM-DD）
current_date=$(date +%Y-%m-%d 2>/dev/null || echo "unknown_date")

# 在 CSV_PATH 下创建日期子目录
output_dir_with_date="${CSV_PATH}/${current_date}"
mkdir -p "$output_dir_with_date"

# 定义汇总的 CSV 文件路径
summary_csv="${output_dir_with_date}/result_${timestamp}.csv"
temp_csv="${output_dir_with_date}/temp_${timestamp}.csv"

# 创建临时文件存储所有结果
>"$temp_csv"

# 初始化汇总 CSV 文件，写入表头
echo "Trace,Cache Size,KIOPS,BW(MiB/s),Timestamp,SPDK Branch,DAS Version,Hit Ratio(%),Clean Ratio(%),Cache Read(GiB),Cache Write(GiB),Core Read(GiB),Latency(us)" >"$summary_csv"

# 辅助函数：将字节转换为GiB
bytes_to_gib() {
    echo "scale=2; $1 / (1024 * 1024 * 1024)" | bc
}

# 辅助函数：将ticks转换为微秒
ticks_to_us() {
    local ticks=$1
    local tick_rate=$2
    echo "scale=2; ($ticks * 1000000) / $tick_rate" | bc
}

# 辅助函数：解析CAS JSON文件
parse_cas_json() {
    local file=$1
    if [ ! -f "$file" ]; then
        echo "Warning: CAS JSON file not found: $file" >&2
        echo "0,0" # 返回默认值
        return
    fi
    
    # 使用grep和sed提取数据（因为服务器可能没有安装jq）
    echo "Parsing CAS JSON file: $file" >&2
    
    # 显示文件内容的前几行，帮助调试
    echo "File content preview:" >&2
    head -n 20 "$file" >&2
    
    # 尝试不同的匹配模式
    local hit_ratio=0
    local clean_ratio=0
    # 使用jq提取命中率和clean比例（如果jq不可用则使用grep和sed）
    local hit_ratio=$(jq -r '.requests.rd_hits.percentage' "$file")
    local clean_ratio=$(jq -r '.usage.clean.percentage' "$file")
    # 确保有数值
    hit_ratio=${hit_ratio:-0}
    clean_ratio=${clean_ratio:-0}
    
    echo -e "${WARNING}Final values - Hit Ratio: $hit_ratio, Clean Ratio: $clean_ratio" >&2
    echo "$hit_ratio,$clean_ratio"
}

# 辅助函数：解析iostat JSON文件
parse_iostat_json() {
    local file=$1
    if [ ! -f "$file" ]; then
        echo "0,0,0,0" # 返回默认值
        return
    fi
    
    # 使用grep和sed提取数据（因为服务器可能没有安装jq）
    local tick_rate=$(grep '"tick_rate"' "$file" | sed 's/.*: \([0-9]*\).*/\1/')
    
    # 提取nvme设备的数据
    local nvme_section=$(sed -n '/\"name\": \"nvme0n1\"/,/}/p' "$file")
    local cache_read_bytes=$(echo "$nvme_section" | grep '"bytes_read"' | sed 's/.*: \([0-9]*\).*/\1/')
    local cache_write_bytes=$(echo "$nvme_section" | grep '"bytes_written"' | sed 's/.*: \([0-9]*\).*/\1/')
    
    # 提取core设备的数据
    local core_section=$(sed -n '/\"name\": \"core1\"/,/}/p' "$file")
    local core_read_bytes=$(echo "$core_section" | grep '"bytes_read"' | sed 's/.*: \([0-9]*\).*/\1/')
    
    # 提取CAS设备的延迟数据
    local cas_section=$(sed -n '/\"name\": \"CAS1\"/,/}/p' "$file")
    local read_latency_ticks=$(echo "$cas_section" | grep '"read_latency_ticks"' | sed 's/.*: \([0-9]*\).*/\1/')
    local num_read_ops=$(echo "$cas_section" | grep '"num_read_ops"' | sed 's/.*: \([0-9]*\).*/\1/')
    
    # 计算平均延迟（微秒）
    local avg_latency=0
    if [ "$num_read_ops" -gt 0 ]; then
        avg_latency=$(echo "scale=2; ($read_latency_ticks * 1000000) / ($tick_rate * $num_read_ops)" | bc)
    fi
    
    # 转换字节到GiB
    local cache_read_gib=$(bytes_to_gib $cache_read_bytes)
    local cache_write_gib=$(bytes_to_gib $cache_write_bytes)
    local core_read_gib=$(bytes_to_gib $core_read_bytes)
    
    echo "$cache_read_gib,$cache_write_gib,$core_read_gib,$avg_latency"
}

# 遍历 result_dir 目录下的所有 fio_result.log 文件
# 使用关联数组记录已处理的配置目录
declare -A processed_configs

find "$FIO_PATH" -mindepth 2 -maxdepth 2 -type d | while read -r config_dir; do
    # 获取配置目录的父目录（去掉时间戳部分）
    base_config_dir=$(dirname "$config_dir")
    
    # 如果这个配置已经处理过，跳过
    if [[ -n "${processed_configs[$base_config_dir]}" ]]; then
        continue
    fi
    
    # 标记这个配置已经处理
    processed_configs[$base_config_dir]=1

    # 在父目录下获取最新的时间戳文件夹
    latest_timestamp_dir=$(ls -td "$base_config_dir"/*/ 2>/dev/null | head -n1)

    if [ -z "$latest_timestamp_dir" ]; then
        echo "Warning: No timestamp directories found in $base_config_dir"
        continue
    fi
                                
    # 处理最新时间戳文件夹下的 fio_result.log
    file="$latest_timestamp_dir/fio_result.log"
    if [ ! -f "$file" ]; then
        echo "Warning: No fio_result.log found in $latest_timestamp_dir"
        continue
    fi

    # 提取路径信息
    dir_path=$(dirname "$(dirname "$file")")
    pattern_full=$(basename "$dir_path")

    # 提取算法名称（+号前的部分）和trace名称（+号后的部分）
    algorithm=${pattern_full%%+*}
    trace_name=${pattern_full#*+}

    # 设置其他字段的默认值
    vm_type="unknown"
    pattern="unknown"
    cache_config="unknown"
    
    # 获取SPDK分支和DAS版本信息
    # spdk_branch=$(get_spdk_branch)  # 使用config.sh中定义的函数获取SPDK分支
    # das_version="unknown"  # TODO: 获取DAS项目的分支名

    # 从文件末尾的 TEST_METADATA 标签中获取 cache_size 和时间戳
    # metadata_line=$(grep "TEST_METADATA:" "$file" || echo "")
    # if [[ $metadata_line =~ TEST_METADATA:\ *CACHE_SIZE=([0-9]+),\ *TIMESTAMP=([0-9_]+) ]]; then
    #     cache_sizes="${BASH_REMATCH[1]}"
    #     test_timestamp="${BASH_REMATCH[2]}"
    #     echo "Found metadata: CACHE_SIZE=$cache_sizes, TIMESTAMP=$test_timestamp"
    # else
    #     # 如果没有找到 metadata，使用原来的方式作为备选
    #     if [[ $trace_name =~ ^ali-dev-3-part-[0-9]$ ]]; then
    #         cache_sizes="683"
    #     else
    #         cache_sizes=${replay_trace_config[$trace_name]}
    #     fi
    #     # 如果没有找到metadata中的时间戳，使用目录名作为时间戳
    #     test_timestamp=$(basename "$(dirname "$file")")
    #     echo -e "\033[31mWarning: 在fio result末行未找到信息 $trace_name in $file，使用目录名作为时间戳\033[0m"
    # fi

    # # 如果没有找到对应的 cache_size，跳过
    # if [[ -z "$cache_sizes" ]]; then
    #     echo "Warning: No cache size found for Trace $trace_name in $file"
    #     continue
    # fi

    # 提取 IOPS 和 BW 的值
    # IOPS格式可能是: "read: IOPS=7538" 或 "read: IOPS=7.5k" 或 "  read: IOPS=11.6k"
    iops_line=$(grep "read: IOPS=" "$file" || echo "")
    if [[ $iops_line =~ IOPS=([0-9.]+)k ]]; then
        # 如果是k单位，直接使用数值
        kiops=${BASH_REMATCH[1]}
    else
        # 如果没有单位，需要除以1000
        raw_iops=$(echo "$iops_line" | grep -oP 'IOPS=\K[0-9.]+' || echo "0")
        kiops=$(echo "scale=2; $raw_iops / 1000" | bc)
    fi

    # BW格式示例: "READ: bw=49.9MiB/s (52.3MB/s)"
    # 先尝试匹配MiB/s格式
    bw=$(grep "READ: bw=" "$file" | grep -oP 'bw=\K[0-9.]+(?=MiB/s)' || echo "")
    
    # 如果没有找到MiB/s格式，尝试匹配MB/s格式并转换
    if [ -z "$bw" ]; then
        mb_bw=$(grep "READ: bw=" "$file" | grep -oP 'bw=\K[0-9.]+(?=MB/s)' || echo "0")
        # 将MB/s转换为MiB/s (1 MB = 0.953674 MiB)
        bw=$(echo "scale=2; $mb_bw * 0.953674" | bc)
    fi

    #* 提取Cache信息
    # 构建相应的JSON文件路径
    # cas_json="${RESULT_BASE}/cas_log/${algorithm}_${trace_name}_${test_timestamp}_CAS1.json"
    # echo "Looking for CAS JSON at: $cas_json" >&2
    # iostat_json="${RESULT_BASE}/iostat/${algorithm}_${trace_name}_${test_timestamp}_iostat.json"
    # echo "Looking for iostat JSON at: $iostat_json" >&2
    
    # 解析JSON文件
    # IFS=',' read -r hit_ratio clean_ratio <<< $(parse_cas_json "$cas_json") # 提取Cache Hit Ratio和Clean Ratio
    # IFS=',' read -r cache_read cache_write core_read avg_latency <<< $(parse_iostat_json "$iostat_json")
    
    # 存储测试结果（按新格式存储）
    # echo "$trace_name,$cache_sizes,$kiops,$bw,$test_timestamp,$spdk_branch,$das_version,$hit_ratio,$clean_ratio,$cache_read,$cache_write,$core_read,$avg_latency" >>"$temp_csv"
    echo "$trace_name,$kiops,$bw" >>"$temp_csv"

    echo "Processing $file:"
    echo "  Trace: $trace_name"
    # echo "  Cache Size: $cache_sizes"
    echo "  KIOPS: $kiops"
    echo "  BW(MiB/s): $bw"
    # echo "  Timestamp: $test_timestamp"
    # echo "  SPDK Branch: $spdk_branch"
    # echo "  DAS Version: $das_version"
    # echo "  Hit Ratio: $hit_ratio%"
    # echo "  Clean Ratio: $clean_ratio%"
    # echo "  Cache Read: $cache_read GiB"
    # echo "  Cache Write: $cache_write GiB"
    # echo "  Core Read: $core_read GiB"
    # echo "  Average Latency: $avg_latency us"
done

# 对临时文件进行排序（按trace名称排序）
sort -t',' -k1 "$temp_csv" >"${temp_csv}.sorted"

# 合并表头和排序后的数据
cat "$summary_csv" "${temp_csv}.sorted" >"${summary_csv}.tmp" && mv "${summary_csv}.tmp" "$summary_csv"

# 清理临时文件
rm -f "$temp_csv" "${temp_csv}.sorted"

echo "All files processed. Summary CSV saved to $summary_csv"

# 服务器暂时装不了panda包
# # 转换CSV到XLSX并追加到结果文件
# if command -v python3 >/dev/null 2>&1; then
#     echo "Converting CSV to XLSX..."
#     chmod +x "${SCRIPT_DIR}/script/csv2xlsx.py"
#     chmod +x "${SCRIPT_DIR}/script/append_results.py"

#     # 先转换为xlsx
#     xlsx_file="${summary_csv%.csv}.xlsx"
#     python3 "${SCRIPT_DIR}/script/csv2xlsx.py" "$summary_csv"

#     # 然后追加到汇总结果文件
#     echo "Appending results to summary file..."
#     python3 "${SCRIPT_DIR}/script/append_results.py" "$xlsx_file"
# else
#     echo "Warning: Python3 not found, skipping XLSX conversion and appending"
# fi
