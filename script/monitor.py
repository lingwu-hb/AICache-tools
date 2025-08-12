#!/usr/bin/env python3

# ./monitor_ocf_stats.py CAS1
# 调用SPDK RPC, 监视OCF的性能
# 可选参数：
# -i 或 --interval：设置监控间隔（秒）
# -l 或 --log：指定日志文件路径

import subprocess
import json
import time
from datetime import datetime
import argparse
import os
import csv
import threading
import sys
import select

import os

HOME_PATH = "/home/hb"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SPDK_PATH = os.getenv("SPDK_PATH", "/home/hb/spdk")
LOG_PATH = os.getenv("LOG_PATH", os.path.join(SPDK_PATH, "log")) # /home/hb/spdk/log
RESULT_BASE = os.getenv("RESULT_BASE", os.path.join(HOME_PATH, "AICache-tools")) # /home/hb/AICache-tools

rpc_path = os.path.join(SPDK_PATH, "scripts/rpc.py")
default_log_file = os.path.join(RESULT_BASE, "ocf_stats/ocf_stats.log") # /home/hb/AICache-tools/ocf_stats/ocf_stats.log

# 添加颜色输出类
class ColorOutput:
    """终端彩色输出"""
    INFO = '\033[92m'      # 绿色
    WARNING = '\033[93m'   # 黄色
    ERROR = '\033[91m'     # 红色
    ENDC = '\033[0m'       # 结束颜色
    BOLD = '\033[1m'       # 粗体
    
    @staticmethod
    def info(msg):
        """打印信息"""
        print(f"{ColorOutput.INFO}[INFO]{ColorOutput.ENDC} {msg}")
        
    @staticmethod
    def warning(msg):
        """打印警告"""
        print(f"{ColorOutput.WARNING}[WARNING]{ColorOutput.ENDC} {msg}")
        
    @staticmethod
    def error(msg):
        """打印错误"""
        print(f"{ColorOutput.ERROR}[ERROR]{ColorOutput.ENDC} {msg}")



class OCFMonitor:
    def __init__(self, cache_name, interval=5, log_file="ocf_stats.log"):
        """初始化OCF监控器
        
        Args:
            cache_name: OCF缓存设备名称
            interval: 统计信息收集间隔(秒)
            log_file: 日志文件路径
        """
        self.cache_name = cache_name
        self.interval = interval
        self.log_file = log_file
        self.rpc_path = rpc_path
        # CSV表头
        self.headers = [
            "时间",
            "总容量(4KiB块)",
            "已用空间(块)",
            "已用空间(%)",
            "脏数据(块)",
            "脏数据(%)",
            "读命中数",
            "读命中率(%)",
            "读部分未命中数",
            "读部分未命中率(%)",
            "读完全未命中数",
            "读完全未命中率(%)",
            "读直通数",
            "写命中数",
            "写命中率(%)",
            "写部分未命中数",
            "写部分未命中率(%)",
            "写完全未命中数",
            "写完全未命中率(%)",
            "写直通数",
            "核心卷读(块)",
            "核心卷写(块)",
            "缓存卷读(块)",
            "缓存卷写(块)",
            "总错误数"
        ]
        self.latest_csv_data = None
        self.running = True
        self.key_thread = None

    def get_stats(self):
        """获取OCF统计信息"""
        try:
            cmd = [self.rpc_path, "bdev_ocf_get_stats", self.cache_name]
            result = subprocess.run(cmd, capture_output=True, text=True)
            return json.loads(result.stdout)
        except Exception as e:
            ColorOutput.error(f"获取统计信息失败: {e}")
            return None

    def format_stats(self, stats):
        """格式化统计信息为两种格式：显示格式和CSV格式"""
        if not stats:
            return "统计信息获取失败", None

        # 数据类型转换函数
        def safe_int(value, default=0):
            try:
                return int(value)
            except (ValueError, TypeError):
                return default

        def safe_float(value, default=0.0):
            try:
                return float(value)
            except (ValueError, TypeError):
                return default

        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        display_output = []
        display_output.append("="*60)
        display_output.append(f"时间: {timestamp}".center(60))
        display_output.append("="*60)
        
        usage = stats["usage"]
        total_blocks = safe_int(usage['occupancy']['count']) + safe_int(usage['free']['count'])
        display_output.append("\n【缓存水位】")
        display_output.append(f"{'总容量:':<15} {total_blocks:>10} 个4KiB块")
        display_output.append(f"{'已使用:':<15} {safe_int(usage['occupancy']['count']):>10} 块 ({safe_float(usage['occupancy']['percentage']):>6.2f}%)")
        display_output.append(f"{'脏数据:':<15} {safe_int(usage['dirty']['count']):>10} 块 ({safe_float(usage['dirty']['percentage']):>6.2f}%)")
        
        req = stats["requests"]
        display_output.append("\n【请求统计】")
        display_output.append("读请求:")
        display_output.append(f"  {'命中:':<15} {safe_int(req['rd_hits']['count']):>10} 次 ({safe_float(req['rd_hits']['percentage']):>6.2f}%)")
        display_output.append(f"  {'部分未命中:':<15} {safe_int(req['rd_partial_misses']['count']):>10} 次 ({safe_float(req['rd_partial_misses']['percentage']):>6.2f}%)")
        display_output.append(f"  {'完全未命中:':<15} {safe_int(req['rd_full_misses']['count']):>10} 次 ({safe_float(req['rd_full_misses']['percentage']):>6.2f}%)")
        display_output.append(f"  {'直通:':<15} {safe_int(req['rd_pt']['count']):>10} 次")
        
        display_output.append("写请求:")
        display_output.append(f"  {'命中:':<15} {safe_int(req['wr_hits']['count']):>10} 次 ({safe_float(req['wr_hits']['percentage']):>6.2f}%)")
        display_output.append(f"  {'部分未命中:':<15} {safe_int(req['wr_partial_misses']['count']):>10} 次 ({safe_float(req['wr_partial_misses']['percentage']):>6.2f}%)")
        display_output.append(f"  {'完全未命中:':<15} {safe_int(req['wr_full_misses']['count']):>10} 次 ({safe_float(req['wr_full_misses']['percentage']):>6.2f}%)")
        display_output.append(f"  {'直通:':<15} {safe_int(req['wr_pt']['count']):>10} 次 ({safe_float(req['wr_pt']['percentage']):>6.2f}%)")

        blocks = stats["blocks"]
        display_output.append("\n【块统计】")
        display_output.append("核心卷:")
        display_output.append(f"  {'读:':<15} {safe_int(blocks['core_volume_rd']['count']):>10} 块")
        display_output.append(f"  {'写:':<15} {safe_int(blocks['core_volume_wr']['count']):>10} 块")
        display_output.append("缓存卷:")
        display_output.append(f"  {'读:':<15} {safe_int(blocks['cache_volume_rd']['count']):>10} 块")
        display_output.append(f"  {'写:':<15} {safe_int(blocks['cache_volume_wr']['count']):>10} 块")

        errors = stats["errors"]
        display_output.append("\n【错误统计】")
        if errors["total"]["count"] > 0:
            display_output.append(f"{'总错误数:':<15} {safe_int(errors['total']['count']):>10}")
            display_output.append(f"{'核心卷错误:':<15} {safe_int(errors['core_volume_total']['count']):>10}")
            display_output.append(f"{'缓存卷错误:':<15} {safe_int(errors['cache_volume_total']['count']):>10}")
            # 详细错误信息
            if errors.get("core_volume_rd", {}).get("count", 0) > 0:
                display_output.append(f"{'核心卷读错误:':<15} {safe_int(errors['core_volume_rd']['count']):>10}")
            if errors.get("core_volume_wr", {}).get("count", 0) > 0:
                display_output.append(f"{'核心卷写错误:':<15} {safe_int(errors['core_volume_wr']['count']):>10}")
            if errors.get("cache_volume_rd", {}).get("count", 0) > 0:
                display_output.append(f"{'缓存卷读错误:':<15} {safe_int(errors['cache_volume_rd']['count']):>10}")
            if errors.get("cache_volume_wr", {}).get("count", 0) > 0:
                display_output.append(f"{'缓存卷写错误:':<15} {safe_int(errors['cache_volume_wr']['count']):>10}")
        else:
            display_output.append("无错误")

        display_output.append("\n" + "="*60 + "\n")

        # 2. CSV格式数据
        csv_data = [
            timestamp,
            total_blocks,
            safe_int(usage['occupancy']['count']),
            safe_float(usage['occupancy']['percentage']),
            safe_int(usage['dirty']['count']),
            safe_float(usage['dirty']['percentage']),
            safe_int(req['rd_hits']['count']),
            safe_float(req['rd_hits']['percentage']),
            safe_int(req['rd_partial_misses']['count']),
            safe_float(req['rd_partial_misses']['percentage']),
            safe_int(req['rd_full_misses']['count']),
            safe_float(req['rd_full_misses']['percentage']),
            safe_int(req['rd_pt']['count']),
            safe_int(req['wr_hits']['count']),
            safe_float(req['wr_hits']['percentage']),
            safe_int(req['wr_partial_misses']['count']),
            safe_float(req['wr_partial_misses']['percentage']),
            safe_int(req['wr_full_misses']['count']),
            safe_float(req['wr_full_misses']['percentage']),
            safe_int(req['wr_pt']['count']),
            safe_int(blocks['core_volume_rd']['count']),
            safe_int(blocks['core_volume_wr']['count']),
            safe_int(blocks['cache_volume_rd']['count']),
            safe_int(blocks['cache_volume_wr']['count']),
            safe_int(errors["total"]["count"])
        ]

        return "\n".join(display_output), csv_data

    def write_log(self, csv_data):
        """以CSV格式写入日志文件"""
        try:
            # 检查文件是否存在
            file_exists = os.path.exists(self.log_file)
            
            with open(self.log_file, "a", newline='', encoding="utf-8") as f:
                writer = csv.writer(f)
                # 如果是新文件，写入表头
                if not file_exists:
                    writer.writerow(self.headers)
                    ColorOutput.info(f"创建新日志文件: {os.path.abspath(self.log_file)}")
                # 写入数据行
                if csv_data:
                    writer.writerow(csv_data)
                    ColorOutput.info(f"数据已写入日志文件: {os.path.abspath(self.log_file)}")
        except Exception as e:
            ColorOutput.error(f"写入日志失败: {e}")

    def keyboard_listener(self):
        """监听键盘输入"""
        ColorOutput.info(f"按 's' 键保存当前数据到日志文件")
        ColorOutput.info(f"按 'q' 键退出监控")
        
        while self.running:
            if sys.stdin in select.select([sys.stdin], [], [], 0)[0]:
                key = sys.stdin.read(1)
                if key == 's':
                    if self.latest_csv_data:
                        ColorOutput.info("正在保存当前数据...")
                        self.write_log(self.latest_csv_data)
                    else:
                        ColorOutput.warning("没有可用的数据可保存")
                elif key == 'q':
                    self.running = False
                    break
            time.sleep(0.1)

    def monitor(self):
        """开始监控"""
        ColorOutput.info(f"开始监控OCF缓存: {self.cache_name}")
        ColorOutput.info(f"日志文件路径: {os.path.abspath(self.log_file)}")
        ColorOutput.info(f"监控间隔: {self.interval}秒")
        print(f"{ColorOutput.BOLD}按 's' 键保存当前数据到日志文件{ColorOutput.ENDC}")
        print(f"{ColorOutput.BOLD}按 'q' 键或Ctrl+C停止监控{ColorOutput.ENDC}\n")

        # 启动键盘监听线程
        self.key_thread = threading.Thread(target=self.keyboard_listener)
        self.key_thread.daemon = True
        self.key_thread.start()

        try:
            while self.running:
                stats = self.get_stats()
                if stats:
                    display_text, csv_data = self.format_stats(stats)
                    print(display_text)
                    self.latest_csv_data = csv_data
                else:
                    ColorOutput.warning("获取统计信息失败")
                time.sleep(self.interval)
        except KeyboardInterrupt:
            self.running = False
            ColorOutput.info("\n监控已停止")
        except Exception as e:
            ColorOutput.error(f"发生错误: {e}")
        finally:
            self.running = False
            if self.key_thread and self.key_thread.is_alive():
                self.key_thread.join(1)

def main():
    parser = argparse.ArgumentParser(description="OCF缓存性能监控工具")
    parser.add_argument("cache_name", help="OCF缓存设备名称")
    parser.add_argument("-i", "--interval", type=int, default=1,
                      help="统计信息收集间隔(秒), 默认1秒")
    parser.add_argument("-l", "--log", default=default_log_file,
                      help="日志文件路径, 默认为ocf_stats.log")
    
    args = parser.parse_args()
    
    monitor = OCFMonitor(args.cache_name, args.interval, args.log)
    monitor.monitor()

if __name__ == "__main__":
    main() 