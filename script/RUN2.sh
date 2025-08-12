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


# 对于每个 trace 
# 首先调用 start_vms_vfio.sh 启动虚拟机
# 然后直接执行 fio 测试
# 测试完成之后，直接调用 stop_vms.sh 停止虚拟机
# 然后循环即可

# 算法循环
for algo in "${algo_config[@]}"; do
    echo "========== 测试算法: $algo =========="

    # Trace循环
    for replay_trace in "${replay_trace_config[@]}"; do
        # 解析trace和缓存大小
        read -r trace_file cache_size <<<"$replay_trace"
        echo "========== 测试:$algo $trace_file (缓存: $cache_size) =========="

        # 调用 start_vms_vfio.sh 启动虚拟机
        ${SCRIPT_DIR}/start_vms_vfio.sh $VM_COUNT "$algo" "$trace_file" "$cache_size"

        # 拷贝模型文件
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

        # 调用 stop_vms.sh 停止虚拟机
        ${SCRIPT_DIR}/stop_vms.sh

    done
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