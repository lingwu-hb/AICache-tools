#!/bin/bash

# Source configuration
SCRIPT_DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
source ${SCRIPT_DIR}/config.sh

# 默认值
VM_BASE_IP=${VM_BASE_IP:-"192.168.122"}
# VM_SSH_PASS=${VM_SSH_PASS:-"openEuler12#$"} # 注释掉密码，因为已配置免密登录
# 如 SPDK_PATH 未定义，设置默认值
SPDK_PATH=${SPDK_PATH:-"/home/lzq/spdk"}

[ $# -lt 4 ] && echo "Usage: $0 --cache-size SIZE --vm-ids VM_IDS" && exit 1

while [[ $# -gt 0 ]]; do
    case $1 in
    --cache-size)
        CACHE_SIZE="$2"
        shift 2
        ;;
    --vm-ids)
        VM_IDS="$2"
        shift 2
        ;;
    *) exit 1 ;;
    esac
done

# set -x
# set -e # 添加错误检查

# 获取PCI设备信息
# PCI_ADDR="0000:83:00.0"
# PCI_DEV="pci_${PCI_ADDR//:/_}"
# virsh nodedev-detach $PCI_DEV

# 1. 检查是否有nvme设备
for vm_id in $(echo $VM_IDS | tr ',' ' '); do
    VM_NAME="vm$(printf "%02d" $vm_id)"
    if ! exec_vm "$VM_NAME" "lsblk" | grep -q nvme; then
        echo -e "${WARNING} VM${vm_id} 无nvme设备"
    fi
done

cd ${SPDK_PATH}

# 2. 删除CAS1, 然后lsblk会发现nvme0n1p0消失了
./scripts/rpc.py bdev_ocf_delete CAS1 &
sleep 10

# 检查设备状态
VM_NAME="vm$(printf "%02d" $vm_id)"
exec_vm "$VM_NAME" "lsblk"

# 3. 删除nvme0n1，按新的CacheSize重建
./scripts/rpc.py bdev_split_delete nvme0n1 &
sleep 10

# # 检查是否成功删除
# count=$(./scripts/rpc.py bdev_get_bdevs | jq '[ .[] | select(.name | startswith("nvme0n1p")) ] | length')
# if [ "$count" -eq 0 ]; then
#     echo "√ nvme0n1p* deleted"
# else
#     echo "nvme0n1p* still exists" >&2
# fi

# ./scripts/rpc.py bdev_nvme_attach_controller -b nvme0 -t PCIe -a ${PCI_ADDR}
if ! ./scripts/rpc.py bdev_split_create -s ${CACHE_SIZE} nvme0n1 1; then
    echo -e "${WARNING} 创建split设备失败"
fi
sleep 5

# 第二次操作，删除nvme0n1，按新的CacheSize重建
./scripts/rpc.py bdev_split_delete nvme0n1 &
sleep 10

if ! ./scripts/rpc.py bdev_split_create -s ${CACHE_SIZE} nvme0n1 1; then
    echo -e "${WARNING} 创建split设备失败"
fi
sleep 5

# 4. 重新创建OCF设备
if ! ./scripts/rpc.py bdev_ocf_create CAS1 wt nvme0n1p0 core1 --cache-line-size 4; then
    echo -e "${WARNING} 创建OCF设备失败"
fi
sleep 5

# 重新配置VFIO传输
# ./scripts/rpc.py nvmf_create_transport -t VFIOUSER
# ./scripts/rpc.py nvmf_create_subsystem nqn.2021-06.io.spdk:ctc_device1 -a -s sys1 -i 1 -I 32760
if ! ./scripts/rpc.py nvmf_subsystem_add_ns nqn.2021-06.io.spdk:ctc_device1 CAS1; then
    echo -e "${WARNING} 添加namespace失败"
fi
sleep 5
# ./scripts/rpc.py nvmf_subsystem_add_listener nqn.2021-06.io.spdk:ctc_device1 -t VFIOUSER -a /var/run -s 0

# #  创建临时XML文件
# # 重新附加设备到VM，验证lsblk是否看到nvme0n1
# cat >/tmp/vfio.xml <<'EOF'
# <hostdev mode='subsystem' type='pci' managed='yes'>
#     <source>
#         <address domain='0x0000' bus='0x83' slot='0x00' function='0x0'/>
#     </source>
# </hostdev>
# EOF

# for vm_id in $(echo $VM_IDS | tr ',' ' '); do
#     VM_NAME="vm$(printf "%02d" $vm_id)"
#     virsh attach-device $VM_NAME /tmp/vfio.xml --current
# done

# 检查是否重新发现了nvme设备
for vm_id in $(echo $VM_IDS | tr ',' ' '); do
    VM_NAME="vm$(printf "%02d" $vm_id)"
    echo -e "${INFO} VM${vm_id} 新的设备列表:"
    list=$(exec_vm "$VM_NAME" "lsblk")
    echo "$list"
    if ! echo "$list" | grep -q nvme; then
        echo -e "${WARNING} VM${vm_id} resize后未找到NVMe设备"
        exit 1
    fi
done

# 清理
rm -f /tmp/vfio.xml
# 清理缓存
echo 3 >/proc/sys/vm/drop_caches

# 为每个VM清理缓存
for vm_id in $(echo $VM_IDS | tr ',' ' '); do
    VM_NAME="vm$(printf "%02d" $vm_id)"
    if ! exec_vm "$VM_NAME" "echo 3 > /proc/sys/vm/drop_caches"; then
        echo -e "${WARNING} VM ${vm_id} 清理缓存失败"
    fi
done