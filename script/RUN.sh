#!/bin/bash
# 优化的批量测试脚本，避免为每个trace重启虚拟机
# 使用热插拔方式重载SPDK磁盘

# Source configuration
SCRIPT_DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
source ${SCRIPT_DIR}/config.sh

# 测试trace配置
replay_trace_config=(
    "mds_1.txt 4300"
	"proj_0.txt 91"
	"proj_3.txt 270"
	"prxy_0.txt 63"
	"rsrch_2.txt 68"
	"src1_2.txt 81"
	"src2_1.txt 981"
	"src2_2.txt 1040"
	"stg_1.txt 4075"
	"ts_0.txt 51"
	"usr_0.txt 109"
	"web_0.txt 369"
	"web_1.txt 188"
	"prn_0.txt 193"
    "ali-dev-3.txt 8200"
	"ali-dev-5.txt 91"
)

# 算法配置(libdas.so)
algo_config=(
    "das-bind"
    # "no_prefetch"
    # 可以根据需要添加更多的算法
)

# 虚拟机数量
VM_COUNT=1

# 日志设置
log_file="${LOG_PATH}/RUN_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$log_file") 2>&1

echo "========== $(date) =========="

# 获取第一个trace和缓存大小用于初始启动
read -r first_trace first_cache <<<"${replay_trace_config[0]}"

echo "start_vms_vfio.sh..." # 仅需要调用一次
start_time=$(date +%s)
${SCRIPT_DIR}/start_vms_vfio.sh $VM_COUNT "${algo_config[0]}" "$first_trace" "$first_cache"

# 标记第一次运行
first_run=true

# 算法循环
for algo in "${algo_config[@]}"; do
    echo "========== 测试算法: $algo =========="

    # Trace循环
    declare -a retry_traces
    for replay_trace in "${replay_trace_config[@]}"; do
        # 解析trace和缓存大小
        read -r trace_file cache_size <<<"$replay_trace"
        echo "========== 测试:$algo $trace_file (缓存: $cache_size) =========="

        # 对于首次运行，不需要重载磁盘（因为start_vms_vfio.sh已经配置好了）
        echo -e "\n${INFO}调整cache size..."
        retry_count=0
        max_retries=3
        success=false

        while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
            ${SCRIPT_DIR}/reload_nvme.sh --cache-size "$cache_size" --vm-ids "$VM_COUNT"
            if [ $? -eq 0 ]; then
                success=true
            else
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    echo -e "\n${WARNING}调整cache size失败,等待10秒后重试 (尝试 $retry_count/$max_retries)"
                    sleep 10
                fi
            fi
        done

        if [ "$success" = false ]; then
            echo -e "\n${ERROR}调整cache size连续${max_retries}次失败"
            continue
        fi

        # 将 /home/model 下面与 trace 同名的模型文件复制到 /home/hb/DAS_codehub_v2.0/model.txt
        # 去掉 trace_file 中的 .txt 后缀以匹配模型文件名
        model_name=$(basename "$trace_file" .txt)
        source_model="/home/hb/model/model_${model_name}"
        target_model="/home/hb/DAS_codehub_v2.0/model.txt"
        if [ -f "$source_model" ]; then
            cp "$source_model" "$target_model"
            if [ $? -eq 0 ]; then
                echo -e "${INFO} 模型文件 $source_model 成功复制到 $target_model"
            else
                echo -e "${WARNING} 模型文件 $source_model 复制到 $target_model 失败"
            fi
        else
            echo -e "${WARNING} 模型文件 $source_model 不存在"
        fi

        # 执行FIO测试
        echo -e "${INFO} fio_vm_test.sh..."
        ${SCRIPT_DIR}/fio_vm_test.sh "$VM_COUNT" "$algo" "$trace_file" "$cache_size"
        test_status=$?

        # 清理缓存
        echo -e "${INFO} Drop cache..."
        echo 3 >/proc/sys/vm/drop_caches

        # 为每个VM清理缓存
        for ((i = 1; i <= VM_COUNT; i++)); do
            VM_NAME="vm$(printf "%02d" $i)"
            exec_vm "${VM_NAME}" "echo 3 > /proc/sys/vm/drop_caches"
        done
        sleep 3

        # 检查是否有测试失败的标志
        trace_failed=false
        for vm in "${VM_LIST[@]}"; do
            if [ -f "/tmp/fio_test_failed_${vm}" ]; then
                echo -e "\n${ERROR} VM ${vm} 的FIO测试启动失败，将对该trace进行重试"
                rm -f "/tmp/fio_test_failed_${vm}"
                trace_failed=true
            fi
        done
        if [ "$trace_failed" = true ]; then
            retry_traces+=("$replay_trace")
        fi
    done

    # 重试失败的trace
    if [ ${#retry_traces[@]} -gt 0 ]; then
        echo -e "\n${INFO} 开始重试失败的trace..."
        for replay_trace in "${retry_traces[@]}"; do
            # 解析trace和缓存大小
            read -r trace_file cache_size <<<"$replay_trace"
            echo "========== 重试测试:$algo $trace_file (缓存: $cache_size) =========="

            # 对于首次运行，不需要重载磁盘（因为start_vms_vfio.sh已经配置好了）
            echo -e "\n${INFO}调整cache size..."
            retry_count=0
            max_retries=3
            success=false

            while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
                ${SCRIPT_DIR}/reload_nvme.sh --cache-size "$cache_size" --vm-ids "$VM_COUNT"
                if [ $? -eq 0 ]; then
                    success=true
                else
                    retry_count=$((retry_count + 1))
                    if [ $retry_count -lt $max_retries ]; then
                        echo -e "\n${WARNING}调整cache size失败,等待10秒后重试 (尝试 $retry_count/$max_retries)"
                        sleep 10
                    fi
                fi
            done

            if [ "$success" = false ]; then
                echo -e "\n${ERROR}调整cache size连续${max_retries}次失败"
                continue
            fi

            # 将 /home/model 下面与 trace 同名的模型文件复制到 /home/hb/DAS_codehub_v2.0/model.txt
            # 去掉 trace_file 中的 .txt 后缀以匹配模型文件名
            model_name=$(basename "$trace_file" .txt)
            source_model="/home/hb/model/model_${model_name}"
            target_model="/home/hb/DAS_codehub_v2.0/model.txt"
            if [ -f "$source_model" ]; then
                cp "$source_model" "$target_model"
                if [ $? -eq 0 ]; then
                    echo -e "${INFO} 模型文件 $source_model 成功复制到 $target_model"
                else
                    echo -e "${WARNING} 模型文件 $source_model 复制到 $target_model 失败"
                fi
            else
                echo -e "${WARNING} 模型文件 $source_model 不存在"
            fi

            # 执行FIO测试
            echo -e "${INFO} fio_vm_test.sh..."
            ${SCRIPT_DIR}/fio_vm_test.sh "$VM_COUNT" "$algo" "$trace_file" "$cache_size"
            test_status=$?

            # 清理缓存
            echo -e "${INFO} Drop cache..."
            echo 3 >/proc/sys/vm/drop_caches

            # 为每个VM清理缓存
            for ((i = 1; i <= VM_COUNT; i++)); do
                VM_NAME="vm$(printf "%02d" $i)"
                exec_vm "${VM_NAME}" "echo 3 > /proc/sys/vm/drop_caches"
            done
            sleep 3
        done
    fi
done

# 测试完成后停止虚拟机
echo "所有测试完成，停止虚拟机..."
${SCRIPT_DIR}/stop_vms.sh

# 生成测试报告
if [[ -x "${SCRIPT_DIR}/gen_io.py" ]]; then
    echo "生成测试报告..."
    # python3 ${SCRIPT_DIR}/parse_fio.py
    bash gen_io.py
fi

echo "===== 批量测试结束 $(date) ====="