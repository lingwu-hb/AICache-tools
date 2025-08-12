#!/bin/bash

# Source configuration
SCRIPT_DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
source ${SCRIPT_DIR}/config.sh

# Command line arguments
VM_NUM=$1
PATTERN=$2
FIO_REPLAY_TRACE=$3
CACHE_SIZE=$4

# Validate inputs
if [ $# != 4 ]; then
    echo "Usage: $0 VM_NUM PATTERN FIO_REPLAY_TRACE CACHE_SIZE"
    echo "  VM_NUM: Number of VMs to start (1 or 5)"
    echo "  PATTERN: Test pattern (baseline/ocf_nopf/ocf_das/etc.)"
    echo "  FIO_REPLAY_TRACE: FIO replay trace file"
    echo "  CACHE_SIZE: Cache size in MB"
    exit 1
fi

echo -e "${INFO} 检查环境..."

# Validate VM number
if [[ ${VM_NUM} -ne 1 && ${VM_NUM} -ne 5 ]]; then
    echo -e "${ERROR} Invalid VM_NUM. Allowed values are 1 and 5."
    exit 1
fi

# Calculate cache partition size
if [[ ${VM_NUM} == 1 ]]; then
    CACHE_PARTITION=${CACHE_SIZE}
elif [[ ${VM_NUM} == 5 ]]; then
    CACHE_PARTITION=$((CACHE_SIZE * VM_NUM * 2))
fi

# Check if cache device is system disk
if echo "pvs" | grep -q "\<${CACHE_DEVICE}\>"; then
    echo -e "${ERROR} ${CACHE_DEVICE} is the system installation disk"
    exit 1
fi

# Sync time
systemctl stop ntpd
ntpdate ceph1
hwclock -w

# Ceph 状态检查
ceph_status=$(ceph -s 2>/dev/null)
if [[ $ceph_status == *"HEALTH_ERR"* ]]; then
    echo -e "${ERROR} Cluster health check failed"
    exit 1
fi

# Prepare libdas.so based on pattern
echo -e "${INFO} 根据算法模式（PATTERN）准备库文件..."
if [[ ${PATTERN} != baseline ]]; then
    das_so_path=""
    case ${PATTERN} in
    ocf_nopf) das_so_path="no_prefetch" ;;
    ocf_seq) das_so_path="seq" ;;
    ocf_seq_large) das_so_path="seq_large" ;;
    ocf_seq_self) das_so_path="seq_self" ;;
    seq_512) das_so_path="seq_512-512" ;;
    seq_64_512) das_so_path="seq_64-512" ;;
    seq_4reqlen) das_so_path="seq_4reqlen" ;;
    seq_4reqlen_bind) das_so_path="seq_4reqlen_bind" ;;
    var_max) das_so_path="var_max" ;;
    fix_max_512) das_so_path="fix_max_512" ;;
    fix_max_64) das_so_path="fix_max_64" ;;
    no_prefetch) das_so_path="das-final-test/no_prefetch" ;;
    das-ori) das_so_path="das-final-test/das-ori" ;;
    das-bind) das_so_path="das-final-test/das-bind" ;;
    das-bind-adaptive) das_so_path="das-final-test/das-bind-adaptive" ;;
    das-bind-adaptive-64k) das_so_path="das-final-test/das-bind-adaptive-64k" ;;
    das-bind-adaptive-64k-feedback) das_so_path="das-final-test/das-bind-adaptive-64k-feedback" ;;
    das-bind-adaptive-64k-feedback-distance) das_so_path="das-final-test/das-bind-adaptive-64k-feedback-distance" ;;
    belief_io) das_so_path="belief_io" ;;
    belief_page) das_so_path="belief_page" ;;
    belief_ori) das_so_path="belief_ori" ;;
    belief_io_*) das_so_path="belief/belief_io_${PATTERN#belief_io_}" ;;
    belief_page_*) das_so_path="belief/belief_page_${PATTERN#belief_page_}" ;;
    das_belief) das_so_path="das_belief" ;;
    seq_8) das_so_path="seq_8" ;;
    seq_64_256) das_so_path="seq_64_256" ;;
    *)
        echo "Unknown pattern: ${PATTERN}"
        exit 1
        ;;
    esac
    cp ${HOME_PATH}/das-so/${das_so_path}/libdas.so ${SPDK_PATH}/
fi

# SPDK setup
cd ${SPDK_PATH}
spdk_branch=$(git branch --show-current)

echo -e "${INFO} SPDK branch: ${spdk_branch}"

${SPDK_PATH}/scripts/setup.sh cleanup &>/dev/null
sleep 2
${SPDK_PATH}/scripts/setup.sh reset &>/dev/null
sleep 2
${SPDK_PATH}/scripts/setup.sh &>/dev/null
sleep 2
${SPDK_PATH}/scripts/setup.sh status

# Configure hugepages
echo 0 >/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
echo 3 >/proc/sys/vm/drop_caches

_vm_mem=$((${VM_NUM} * ${VM_MEM} * 1024 * 1024))
_pg_num=610000
_single_vm_pg=20000

if [[ ${_vm_mem} -lt ${FREE_SYS_MEM} ]]; then
    if [[ ${VM_NUM} == 1 ]]; then
        for node in node0 node1 node2 node3; do
            echo 15000 >"/sys/devices/system/node/${node}/hugepages/hugepages-2048kB/nr_hugepages"
        done
    elif [[ ${VM_NUM} == 5 ]]; then
        for node in node0 node1; do
            echo ${_pg_num} >"/sys/devices/system/node/${node}/hugepages/hugepages-2048kB/nr_hugepages"
        done
        for node in node2 node3; do
            echo ${_single_vm_pg} >"/sys/devices/system/node/${node}/hugepages/hugepages-2048kB/nr_hugepages"
        done
    fi
else
    echo "VM capacity exceeds system memory. Huge page allocation failed."
    exit 1
fi

# 输出当前测试的配置信息
echo -e "${INFO} ==================== Test Configuration ===================="
echo -e "${INFO} Pattern:     ${PATTERN}"
echo -e "${INFO} Trace File:  ${FIO_REPLAY_TRACE}"
echo -e "${INFO} Cache Size:  ${CACHE_SIZE}MB"
echo -e "${INFO} VM Count:    ${VM_NUM}"
echo -e "${INFO} Cache Part:  ${CACHE_PARTITION}MB"
echo -e "${INFO} ============================================================"

# spdk/vfiouser process starting
mkdir -p ${RESULT_BASE}/log
datetime=$(date "+%m%d_%H%M")
nqnuuid=$(date "+%H%M")

#LD_PRELOAD=/usr/lib/gcc/aarch64-linux-gnu/7.3.0/libasan.so

#-e enable record trace
cd ${SPDK_PATH} && LD_LIBRARY_PATH=${SPDK_PATH}/build/lib:${SPDK_PATH}/dpdk/build/lib:./ ${SPDK_PATH}/build/bin/nvmf_tgt -e vbdev_ocf >${RESULT_BASE}/log/nvmf_${datetime}_${PATTERN}_${FIO_REPLAY_TRACE}.log 2>&1 & # core 60-63
#cd ${SPDK_HOME} &&  LD_LIBRARY_PATH=build/lib:dpdk/build/lib:./ build/bin/nvmf_tgt -m ${CPU_MASK} -e vbdev_ocf > log/nvmf_${datetime}_${PATTERN}_${FIO_REPLAY_TRACE}.log 2>&1 & # core 60-63
sleep 5

# #record trace
# mkdir -p ${SPDK_PATH}/trace_log
# spdk_pid=$(ps aux | grep nvmf_tgt | grep -v grep | awk '{print $2}')
# cd ${SPDK_PATH} && LD_LIBRARY_PATH=${SPDK_PATH}/build/lib:${SPDK_PATH}/dpdk/build/lib:./ ${SPDK_PATH}/build/bin/spdk_trace_record -q -s nvmf -p ${spdk_pid} -f ${SPDK_PATH}/trace_log/spdk_nvmf_record_${datetime}_${PATTERN}_${FIO_REPLAY_TRACE}.trace &

${SPDK_PATH}/scripts/rpc.py log_set_level ERROR
#./scripts/rpc.py log_set_level ERROR
${SPDK_PATH}/scripts/rpc.py log_set_print_level ERROR
#./scripts/rpc.py log_set_print_level ERROR
${SPDK_PATH}/scripts/rpc.py nvmf_create_transport -t VFIOUSER

# cache partitions preparing
if [[ ${PATTERN} == baseline ]]; then
    echo " there is no need for nvme partitions "
else
    ${SPDK_PATH}/scripts/rpc.py bdev_nvme_attach_controller -b nvme0 -t PCIe -a ${CACHE_PCIE}
    ${SPDK_PATH}/scripts/rpc.py bdev_split_create -s ${CACHE_PARTITION} nvme0n1 1
fi

# 配置VM和测试环境
rm -rf /var/run/vm*
for ((i = 0; i < ${VM_NUM}; i++)); do
    VM_LIST[$i]="vm$(printf "%02d" $(($i + 1)))"
    VM_IP[$i]="${VM_BASE_IP}.$((${VM_START_IP} + i))"

    # 准备bdev
    if [[ ${VM_NUM} == 5 ]]; then
        mkdir -p /var/run/${VM_LIST[$i]}
        # ${SPDK_PATH}/scripts/rpc.py nvmf_create_subsystem nqn.2021-06.io.spdk:ctc_device$((i + 1)) -a -s sys$((i + 1)) -i 1 -I 32760
        # ${SPDK_PATH}/scripts/rpc.py bdev_rbd_create -b core$((2 * ($i + 1) - 1)) ${RBD_POOL} vm$(printf "%02d" $((2 * ($i + 1) - 1))) 512
        # ${SPDK_PATH}/scripts/rpc.py bdev_rbd_create -b core$((2 * (i + 1))) ${RBD_POOL} vm$(printf "%02d" $((2 * ($i + 1)))) 512

        # if [[ ${PATTERN} == das ]]; then
        #     ${SPDK_PATH}/scripts/rpc.py bdev_ocf_create CAS$((2 * ($i + 1) - 1)) wt ${CACHE_DEVICE}p0 core$((2 * (i + 1) - 1)) --cache-line-size ${CACHE_LINE_SIZE}
        #     sleep 30
        #     ${SPDK_PATH}/scripts/rpc.py bdev_ocf_create CAS$((2 * (i + 1))) wt ${CACHE_DEVICE}p0 core$((2 * (i + 1))) --cache-line-size ${CACHE_LINE_SIZE}
        #     sleep 30
        #     ${SPDK_PATH}/scripts/rpc.py nvmf_subsystem_add_ns nqn.2021-06.io.spdk:ctc_device$((i + 1)) CAS$((2 * (i + 1) - 1))
        #     ${SPDK_PATH}/scripts/rpc.py nvmf_subsystem_add_ns nqn.2021-06.io.spdk:ctc_device$((i + 1)) CAS$((2 * (i + 1)))
        # elif [[ ${PATTERN} == baseline ]]; then
        #     ${SPDK_PATH}/scripts/rpc.py nvmf_subsystem_add_ns nqn.2021-06.io.spdk:ctc_device$((i + 1)) core$((2 * (i + 1) - 1))
        #     ${SPDK_PATH}/scripts/rpc.py nvmf_subsystem_add_ns nqn.2021-06.io.spdk:ctc_device$((i + 1)) core$((2 * (i + 1)))
        # else
        #     echo -e "${ERROR} Unsupported test pattern, exit"
        #     exit 1
        # fi
        # ${SPDK_PATH}/scripts/rpc.py nvmf_subsystem_add_listener nqn.2021-06.io.spdk:ctc_device$((i + 1)) -t VFIOUSER -a /var/run/${VM_LIST[$i]} -s 0
    elif [[ ${VM_NUM} == 1 ]]; then
        mkdir -p /var/run/${VM_LIST[$i]}
        # ${SPDK_PATH}/scripts/rpc.py nvmf_create_subsystem nqn.2023-11.io.spdk:node${nqnuuid}$((i + 1)) -a -s sys$((i + 1)) -i 1 -I 32760
        # ${SPDK_PATH}/scripts/rpc.py bdev_rbd_create -b core$((i + 1)) ${RBD_POOL} vm01 512
        # sleep 3

        # if [[ ${PATTERN} == baseline ]]; then
        #     ${SPDK_PATH}/scripts/rpc.py nvmf_subsystem_add_ns nqn.2023-11.io.spdk:node${nqnuuid}$((i + 1)) core$((i + 1))
        # else
        #     ${SPDK_PATH}/scripts/rpc.py bdev_ocf_create CAS$((i + 1)) wt nvme0n1p0 core$((i + 1)) --cache-line-size ${CACHE_LINE_SIZE}
        #     sleep 5 # 确保bdev_ocf_create完成
        #     ${SPDK_PATH}/scripts/rpc.py nvmf_subsystem_add_ns nqn.2023-11.io.spdk:node${nqnuuid}$((i + 1)) CAS$((i + 1))
        # fi
        # ${SPDK_PATH}/scripts/rpc.py nvmf_subsystem_add_listener nqn.2023-11.io.spdk:node${nqnuuid}$((i + 1)) -t VFIOUSER -a /var/run/${VM_LIST[$i]} -s 0
        
        # TODO：
        ${SPDK_PATH}/scripts/rpc.py bdev_rbd_create -b core$((i + 1)) ${RBD_POOL} vm01 512
        ${SPDK_PATH}/scripts/rpc.py bdev_ocf_create CAS$((i + 1)) wt nvme0n1p0 core$((i + 1)) --cache-line-size ${CACHE_LINE_SIZE}
        # 先创建再删除 -> 系统 bug
        # ${SPDK_PATH}/scripts/rpc.py bdev_ocf_delete CAS$((i + 1))
        # ${SPDK_PATH}/scripts/rpc.py bdev_ocf_create CAS$((i + 1)) wt nvme0n1p0 core$((i + 1)) --cache-line-size ${CACHE_LINE_SIZE}


        scripts/rpc.py nvmf_create_subsystem nqn.2021-06.io.spdk:ctc_device1 -a -s sys1 -i 1 -I 32760
        scripts/rpc.py nvmf_subsystem_add_ns nqn.2021-06.io.spdk:ctc_device1 CAS1 #这里写死了
        scripts/rpc.py nvmf_subsystem_add_listener nqn.2021-06.io.spdk:ctc_device1 -t VFIOUSER -a /var/run/${VM_LIST[$i]} -s 0
    fi
    # 启动虚拟机
    virsh define ${VM_CONFIG_PATH}/${VM_LIST[$i]}.xml
    echo 3 >/proc/sys/vm/drop_caches
    start_time=$(date +%s)
    virsh start ${VM_LIST[$i]}
done

sleep 10 # 稍微等待一下让VM开始启动

# TODO：这后面都默认只有一个VM了
# 先检查是否可以连接
echo -e "${INFO} 轮询VM是否可以连接..."
vm_name=${VM_LIST[0]}
while ! virsh list --all | grep ${vm_name}; do
    echo -n "."
    sleep 1
done

# vm已经RUNNING，检查基本命令是否可用
echo -e "${INFO} 检查VM基本功能和Guest Agent状态..."
check_commands=("echo 1" "ls /" "cat /proc/cpuinfo" "free -h")
all_passed=false
guest_agent_ready=false
start_time=$(date +%s)

while [ "$all_passed" = false ] || [ "$guest_agent_ready" = false ]; do
    # 检查基本命令
    if [ "$all_passed" = false ]; then
        all_passed=true
        for cmd in "${check_commands[@]}"; do
            if ! exec_vm "${vm_name}" "$cmd" &>/dev/null; then
                all_passed=false
                elapsed=$(($(date +%s) - start_time))
                echo -ne "\r等待命令可用 ($cmd)... ${elapsed}秒"
                sleep 1
                break
            fi
        done
    fi

    # 检查guest agent状态
    if [ "$guest_agent_ready" = false ]; then
        if virsh qemu-agent-command "${vm_name}" '{"execute":"guest-info"}' &>/dev/null; then
            guest_agent_ready=true
            echo -e "\n${INFO} Guest Agent已就绪"
        else
            elapsed=$(($(date +%s) - start_time))
            echo -ne "\r等待Guest Agent就绪... ${elapsed}秒"
            sleep 1
        fi
    fi

    # 超时检查（5分钟）
    if [ $(($(date +%s) - start_time)) -gt 300 ]; then
        echo -e "\n${ERROR} VM启动超时（5分钟），请检查系统状态"
        exit 1
    fi
done

elapsed=$(($(date +%s) - start_time))
echo -e "\n${INFO} VM已完全就绪，用时${elapsed}秒"