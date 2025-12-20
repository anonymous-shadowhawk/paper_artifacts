#!/usr/bin/env python3
import os
import sys
import time
import json
import random
import subprocess
import signal
import threading
import shutil
import glob
import argparse
import re
import queue
from datetime import datetime
from pathlib import Path


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FT = os.path.dirname(SCRIPT_DIR)
FAULTLAB_DIR = SCRIPT_DIR
BOOT_SCRIPT = os.path.join(FAULTLAB_DIR, "qemu_boot_noninteractive.sh")
RESULTS_DIR = os.path.join(FAULTLAB_DIR, "results")
BACKUP_DIR = os.path.join(FAULTLAB_DIR, "backups")
JOURNAL_TOOL = os.path.join(FT, "journal", "journal_tool") 

BOOT_TIME_FAULTS = ['bit_flip', 'torn_write', 'signature', 'brownout', 'power_cut']
RUNTIME_FAULTS = ['verifier_kill', 'ecc', 'watchdog', 'temperature', 'storage']
ALL_FAULTS = BOOT_TIME_FAULTS + RUNTIME_FAULTS

class FaultInjector:
    
    def __init__(self, verbose=True):
        self.backup_dir = BACKUP_DIR
        self.verbose = verbose
        self.injected_faults = []
        
        os.makedirs(self.backup_dir, exist_ok=True)
        os.makedirs(RESULTS_DIR, exist_ok=True)
        
        if self.verbose:
            self.log("Fault Injector initialized")
    
    def log(self, message):
        if self.verbose:
            timestamp = datetime.now().strftime("%H:%M:%S")
            print(f"[{timestamp}] {message}")
    
    def backup_file(self, filepath):
        if not os.path.exists(filepath):
            self.log(f" Warning: File not found for backup: {filepath}")
            return False
        
        backup_name = f"{os.path.basename(filepath)}.bak"
        backup_path = os.path.join(self.backup_dir, backup_name)
        
        try:
            shutil.copy2(filepath, backup_path)
            self.log(f" Backed up: {os.path.basename(filepath)}")
            return True
        except Exception as e:
            self.log(f" Backup failed: {e}")
            return False
    
    def restore_file(self, filepath):
        backup_name = f"{os.path.basename(filepath)}.bak"
        backup_path = os.path.join(self.backup_dir, backup_name)
        
        if not os.path.exists(backup_path):
            return False
        
        try:
            shutil.copy2(backup_path, filepath)
            self.log(f" Restored: {os.path.basename(filepath)}")
            return True
        except Exception as e:
            self.log(f" Restore failed: {e}")
            return False
    
    def restore_all(self, rebuild_initramfs=True):
        restored = 0
        journal_restored = False
        
        search_paths = [
            f"{FT}/var/pac",
            f"{FT}/boot/fit",
            f"{FT}/tier1_initramfs",
            f"{FT}/tier1_initramfs/rootfs/var/pac"  
        ]
        
        for backup_file in os.listdir(self.backup_dir):
            if backup_file.endswith('.bak'):
                original_name = backup_file[:-4]
                for base_dir in search_paths:
                    original_path = os.path.join(base_dir, original_name)
                    if os.path.exists(original_path) or (original_name == 'journal.dat' and base_dir.endswith('rootfs/var/pac')):
                        backup_path = os.path.join(self.backup_dir, backup_file)
                        os.makedirs(os.path.dirname(original_path), exist_ok=True)
                        shutil.copy2(backup_path, original_path)
                        restored += 1
                        if 'journal' in original_name:
                            journal_restored = True
                        break
        
        if rebuild_initramfs and journal_restored:
            try:
                rootfs_dir = f"{FT}/tier1_initramfs/rootfs"
                img_dir = f"{FT}/tier1_initramfs/img"
                result = subprocess.run(
                    f"cd {rootfs_dir} && find . | cpio -o -H newc 2>/dev/null | gzip -9 > {img_dir}/initramfs.cpio.gz && cp {img_dir}/initramfs.cpio.gz {img_dir}/pac_initramfs.cpio.gz",
                    shell=True, capture_output=True, timeout=30
                )
                if result.returncode == 0:
                    self.log(f" Rebuilt initramfs with clean journal")
            except Exception as e:
                self.log(f" Failed to rebuild initramfs: {e}")
        
        if restored > 0:
            self.log(f" Restored {restored} files")
        return restored
    
    
    def inject_bit_flip(self, filepath, num_flips=1, byte_range=None):
        if not self.backup_file(filepath):
            return None
        
        try:
            with open(filepath, 'r+b') as f:
                data = bytearray(f.read())
                size = len(data)
                
                if size == 0:
                    self.log(f" File is empty: {filepath}")
                    return None
                
                if byte_range:
                    start, end = byte_range
                    start = max(0, min(start, size - 1))
                    end = max(start + 1, min(end, size))
                else:
                    start, end = 0, size
                
                flipped_positions = []
                for _ in range(num_flips):
                    byte_pos = random.randint(start, end - 1)
                    bit_pos = random.randint(0, 7)
                    old_byte = data[byte_pos]
                    data[byte_pos] ^= (1 << bit_pos)
                    new_byte = data[byte_pos]
                    
                    flipped_positions.append({
                        'byte_offset': byte_pos,
                        'bit_position': bit_pos,
                        'old_value': f"0x{old_byte:02x}",
                        'new_value': f"0x{new_byte:02x}"
                    })
                
                f.seek(0)
                f.write(data)
            
            self.log(f" Injected {num_flips} bit flip(s)")
            
            fault_info = {
                'type': 'bit_flip',
                'file': filepath,
                'num_flips': num_flips,
                'file_size': size,
                'positions': flipped_positions,
                'timestamp': time.time()
            }
            
            self.injected_faults.append(fault_info)
            return fault_info
            
        except Exception as e:
            self.log(f" Bit flip injection failed: {e}")
            return None
    
    def inject_journal_crc_corruption(self, filepath):
        if not self.backup_file(filepath):
            return None
        
        try:
            with open(filepath, 'r+b') as f:
                data = bytearray(f.read())
                size = len(data)
                
                if size != 72:
                    self.log(f" Warning: Expected 72-byte journal, got {size} bytes")
                
                
                corrupted_positions = []
                
                for byte_offset in range(32, min(36, size)):
                    old_byte = data[byte_offset]
                    data[byte_offset] = 0xFF  
                    corrupted_positions.append({
                        'byte_offset': byte_offset,
                        'old_value': f"0x{old_byte:02x}",
                        'new_value': '0xff',
                        'location': 'page_a_crc'
                    })
                
                for byte_offset in range(68, min(72, size)):
                    old_byte = data[byte_offset]
                    data[byte_offset] = 0xFF  
                    corrupted_positions.append({
                        'byte_offset': byte_offset,
                        'old_value': f"0x{old_byte:02x}",
                        'new_value': '0xff',
                        'location': 'page_b_crc'
                    })
                
                f.seek(0)
                f.write(data)
            
            self.log(f" ZEROED BOTH journal CRCs (Page A: bytes 32-35, Page B: bytes 68-71)")
            self.log(f"  -> All CRC bytes set to 0xFF (GUARANTEED invalid)")
            
            fault_info = {
                'type': 'journal_crc_corruption',
                'file': filepath,
                'corruption_type': 'zero_crc',
                'bytes_corrupted': len(corrupted_positions),
                'file_size': size,
                'positions': corrupted_positions,
                'timestamp': time.time()
            }
            
            self.injected_faults.append(fault_info)
            return fault_info
            
        except Exception as e:
            self.log(f" Journal CRC corruption failed: {e}")
            return None
    
    def inject_torn_write(self, filepath, truncate_bytes=None):
        if not os.path.exists(filepath):
            self.log(f" File not found: {filepath}")
            return None
        
        if not self.backup_file(filepath):
            return None
        
        try:
            original_size = os.path.getsize(filepath)
            
            if truncate_bytes is None:
                truncate_bytes = random.randint(30, min(55, original_size - 10))
            
            new_size = max(0, original_size - truncate_bytes)
            os.truncate(filepath, new_size)
            
            self.log(f" Torn write: truncated {truncate_bytes} bytes")
            
            fault_info = {
                'type': 'torn_write',
                'file': filepath,
                'original_size': original_size,
                'new_size': new_size,
                'truncated_bytes': truncate_bytes,
                'timestamp': time.time()
            }
            
            self.injected_faults.append(fault_info)
            return fault_info
            
        except Exception as e:
            self.log(f" Torn write injection failed: {e}")
            return None
    
    def inject_signature_corruption(self, fit_file, num_flips=None):
        try:
            file_size = os.path.getsize(fit_file)
            
            if num_flips is None:
                num_flips = random.randint(50, 100)  
            
            sig_area_size = min(100 * 1024, file_size // 2)  
            sig_start = max(0, file_size - sig_area_size)
            sig_end = file_size
            
            self.log(f" Injecting signature corruption ({num_flips} bit flips in last {sig_area_size//1024}KB)")
            
            fault_info = self.inject_bit_flip(fit_file, num_flips=num_flips, byte_range=(sig_start, sig_end))
            
            if fault_info:
                fault_info['type'] = 'signature_corruption'
            
            return fault_info
            
        except Exception as e:
            self.log(f" Signature corruption failed: {e}")
            return None
    
    def inject_brownout_flag(self, journal_path=None):
        if journal_path is None:
            journal_path = f"{FT}/tier1_initramfs/rootfs/var/pac/journal.dat"
        
        journal_tool = f"{FT}/journal/journal_tool"
        
        os.makedirs(os.path.dirname(journal_path), exist_ok=True)
        
        if not os.path.exists(journal_tool):
            self.log(f" journal_tool not found: {journal_tool}")
            return None
        
        if not os.path.exists(journal_path):
            self.log(f"-> Initializing journal at {journal_path}")
            subprocess.run([journal_tool, "init", journal_path], capture_output=True)
        
        result = subprocess.run([journal_tool, "read", journal_path], capture_output=True, text=True)
        current_flags = "0x00000000"
        if result.returncode == 0:
            for line in result.stdout.split('\n'):
                if 'Flags:' in line:
                    import re
                    match = re.search(r'0x[0-9A-Fa-f]+', line)
                    if match:
                        current_flags = match.group(0)
                    break
        
        subprocess.run([journal_tool, "clear-flag", "brownout", journal_path], capture_output=True)
        subprocess.run([journal_tool, "clear-flag", "emergency", journal_path], capture_output=True)
        subprocess.run([journal_tool, "clear-flag", "quarantine", journal_path], capture_output=True)
        subprocess.run([journal_tool, "clear-flag", "dirty", journal_path], capture_output=True)
        
        if not self.backup_file(journal_path):
            return None
        
        result = subprocess.run([journal_tool, "set-flag", "brownout", journal_path], 
                               capture_output=True, text=True)
        
        if result.returncode == 0:
            self.log(f" Brownout flag set ({current_flags} -> 0x00000001)")
            
            verify = subprocess.run([journal_tool, "read", journal_path], capture_output=True, text=True)
            if "BROWNOUT" in verify.stdout:
                self.log(f"   Verified: BROWNOUT flag present in journal")
            else:
                self.log(f"   Warning: BROWNOUT flag not visible in journal output")
            
            self.log(f"-> Rebuilding initramfs with brownout flag...")
            rebuild_result = subprocess.run(
                f"cd {FT}/tier1_initramfs/rootfs && find . | cpio -o -H newc 2>/dev/null | gzip -9 > ../img/pac_initramfs.cpio.gz",
                shell=True, capture_output=True, text=True
            )
            if rebuild_result.returncode == 0:
                self.log(f" Initramfs rebuilt with brownout flag")
            else:
                self.log(f" Initramfs rebuild warning: {rebuild_result.stderr[:100] if rebuild_result.stderr else 'unknown'}")
            
            fault_info = {
                'type': 'brownout_flag',
                'file': journal_path,
                'old_flags': current_flags,
                'new_flags': "0x00000001",
                'timestamp': time.time()
            }
            self.injected_faults.append(fault_info)
            return fault_info
        else:
            self.log(f" Failed to set brownout flag: {result.stderr}")
            return None
    
    def inject_ecc_error(self, count=15):
        self.log(f" Simulating {count} ECC memory errors")
        
        ecc_file = "/tmp/inject_ecc_errors"
        
        try:
            with open(ecc_file, 'w') as f:
                f.write(f"{count}\n")
            
            fault_info = {
                'type': 'ecc_error',
                'count': count,
                'threshold': 10,
                'flag_file': ecc_file,
                'timestamp': time.time()
            }
            
            self.injected_faults.append(fault_info)
            return fault_info
            
        except Exception as e:
            self.log(f" ECC error injection failed: {e}")
            return None
    
    def inject_watchdog_fault(self):
        self.log(" Simulating watchdog timer timeout")
        
        watchdog_file = "/tmp/inject_watchdog_fault"
        
        try:
            with open(watchdog_file, 'w') as f:
                f.write("timeout\n")
                f.write(f"{time.time()}\n")
            
            fault_info = {
                'type': 'watchdog_fault',
                'flag_file': watchdog_file,
                'timestamp': time.time()
            }
            
            self.injected_faults.append(fault_info)
            return fault_info
            
        except Exception as e:
            self.log(f" Watchdog fault injection failed: {e}")
            return None
    
    def inject_temperature_fault(self, temperature=90):
        self.log(f" Simulating critical temperature: {temperature}°C")
        
        temp_file = "/tmp/inject_temperature"
        
        try:
            with open(temp_file, 'w') as f:
                f.write(f"{temperature}\n")
            
            fault_info = {
                'type': 'temperature_fault',
                'temperature_celsius': temperature,
                'critical_threshold': 85,
                'flag_file': temp_file,
                'timestamp': time.time()
            }
            
            self.injected_faults.append(fault_info)
            return fault_info
            
        except Exception as e:
            self.log(f" Temperature fault injection failed: {e}")
            return None
    
    def inject_storage_failure(self):
        self.log(" Simulating storage failure")
        
        flag_file = "/tmp/inject_storage_fault"
        
        try:
            with open(flag_file, 'w') as f:
                f.write("1\n")
            
            fault_info = {
                'type': 'storage_failure',
                'flag_file': flag_file,
                'timestamp': time.time()
            }
            
            self.injected_faults.append(fault_info)
            return fault_info
            
        except Exception as e:
            self.log(f" Storage failure injection failed: {e}")
            return None
    
    def clear_fault_flags(self):
        flags = [
            '/tmp/inject_ecc_errors',
            '/tmp/inject_watchdog_fault',
            '/tmp/inject_temperature',
            '/tmp/inject_storage_fault'
        ]
        
        cleared = 0
        for flag_file in flags:
            if os.path.exists(flag_file):
                os.remove(flag_file)
                cleared += 1
        
        if cleared > 0:
            self.log(f" Cleared {cleared} fault flags")
        return cleared

class QEMUFaultInjector:
    
    def __init__(self, verbose=True, timeout=180, runtime_mode=False):
        self.verbose = verbose
        self.timeout = timeout
        self.runtime_mode = runtime_mode
        self.base_injector = FaultInjector(verbose=verbose)
        
        if not os.path.exists(BOOT_SCRIPT):
            raise FileNotFoundError(f"Boot script not found: {BOOT_SCRIPT}")
        
        if self.verbose:
            self.log(f"QEMU Fault Injector initialized (timeout: {timeout}s)")
    
    def log(self, message):
        if self.verbose:
            timestamp = datetime.now().strftime("%H:%M:%S")
            print(f"[{timestamp}] {message}")
    
    def cleanup_system(self):
        subprocess.run(["pkill", "-9", "qemu-system-aarch64"], stderr=subprocess.DEVNULL, check=False)
        subprocess.run(["pkill", "-9", "qemu"], stderr=subprocess.DEVNULL, check=False)
        subprocess.run(["pkill", "-9", "swtpm"], stderr=subprocess.DEVNULL, check=False)
        
        for pattern in ["/tmp/inject_*", "/tmp/tpm-state*", "/tmp/swtpm*.sock", "/tmp/sh*"]:
            for f in glob.glob(pattern):
                try:
                    if os.path.isdir(f):
                        shutil.rmtree(f)
                    else:
                        os.remove(f)
                except:
                    pass
        
        time.sleep(2)
    
    def reset_journal_to_clean_state(self):
        journal_tool = JOURNAL_TOOL  
        rootfs_journal = f"{FT}/tier1_initramfs/rootfs/var/pac/journal.dat"
        var_journal = f"{FT}/var/pac/journal.dat"
        
        os.makedirs(os.path.dirname(rootfs_journal), exist_ok=True)
        os.makedirs(os.path.dirname(var_journal), exist_ok=True)
        
        for journal_path in [rootfs_journal, var_journal]:
            try:
                subprocess.run([journal_tool, "init", journal_path], capture_output=True, timeout=5, check=False)
                for flag in ['emergency', 'brownout', 'quarantine', 'dirty', 'network_gated']:
                    subprocess.run([journal_tool, "clear-flag", flag, journal_path], capture_output=True, timeout=5, check=False)
                subprocess.run([journal_tool, "reset-tries", journal_path], capture_output=True, timeout=5, check=False)
            except Exception as e:
                self.log(f"   Failed to reset journal at {journal_path}: {e}")
        
        for f in glob.glob(os.path.join(self.base_injector.backup_dir, "*.bak")):
            try:
                os.remove(f)
            except:
                pass
        
        self.log(f"   Journal reset to clean state")
    
    def parse_tier_from_output(self, output_lines):
        tier_timestamps = {}
        final_tier = 0
        
        for line in output_lines:
            line_lower = line.lower()
            
            if ("tier 1" in line_lower and ("operational" in line_lower or "established" in line_lower)) or \
               "t1 operational" in line_lower:
                if 1 not in tier_timestamps:
                    tier_timestamps[1] = time.time()
                final_tier = max(final_tier, 1)
            elif ("tier 2" in line_lower and ("operational" in line_lower or "established" in line_lower)) or \
                 "t2 operational" in line_lower:
                if 2 not in tier_timestamps:
                    tier_timestamps[2] = time.time()
                final_tier = max(final_tier, 2)
            elif ("tier 3" in line_lower and ("operational" in line_lower or "established" in line_lower)) or \
                 "t3 operational" in line_lower:
                if 3 not in tier_timestamps:
                    tier_timestamps[3] = time.time()
                final_tier = max(final_tier, 3)
            
            if "Tier: 1" in line or "Current Tier: 1" in line:
                final_tier = max(final_tier, 1)
            elif "Tier: 2" in line or "Current Tier: 2" in line:
                final_tier = max(final_tier, 2)
            elif "Tier: 3" in line or "Current Tier: 3" in line:
                final_tier = max(final_tier, 3)
            
            if "kernel panic" in line_lower or "emergency mode" in line_lower:
                final_tier = 0
                break
        
        return final_tier, tier_timestamps
    
    def parse_tier_continuously(self, output_lines, tier_history):
        current_tier = 0
        
        for line in output_lines:
            line_lower = line.lower()
            tier_detected = None
            
            if ("tier 1" in line_lower and "established" in line_lower):
                tier_detected = 1
            elif ("tier 2" in line_lower and "established" in line_lower):
                tier_detected = 2
            elif ("tier 3" in line_lower and "established" in line_lower):
                tier_detected = 3
            
            if tier_detected is not None:
                current_tier = tier_detected
                timestamp = time.time()
                if not tier_history or tier_history[max(tier_history.keys())] != tier_detected:
                    tier_history[timestamp] = tier_detected
        
        return current_tier
    
    def boot_qemu_and_measure(self, monitor_duration=60):
        self.log("-> Starting QEMU boot...")
        
        start_time = time.time()
        output_lines = []
        qemu_proc = None
        
        try:
            qemu_proc = subprocess.Popen(
                ["bash", BOOT_SCRIPT],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
                universal_newlines=True,
                preexec_fn=os.setsid
            )
            
            def read_output():
                try:
                    for line in iter(qemu_proc.stdout.readline, ''):
                        output_lines.append(line.rstrip())
                except:
                    pass
            
            reader_thread = threading.Thread(target=read_output, daemon=True)
            reader_thread.start()
            
            time.sleep(monitor_duration)
            
            final_tier, tier_timestamps = self.parse_tier_from_output(output_lines)
            
            if final_tier > 0 and final_tier in tier_timestamps:
                boot_time = tier_timestamps[final_tier] - start_time
            else:
                boot_time = time.time() - start_time
            
            success = final_tier >= 1
            
            self.log(f"  Boot complete: Tier {final_tier}, Time: {boot_time:.2f}s")
            
            return {
                'tier': final_tier,
                'boot_time': boot_time,
                'success': success,
                'recovered': success,
                'tier_timestamps': tier_timestamps,
                'output_lines': len(output_lines),
                'error': None
            }
            
        except Exception as e:
            self.log(f"   Boot failed: {e}")
            return {
                'tier': 0,
                'boot_time': time.time() - start_time,
                'success': False,
                'recovered': False,
                'error': str(e)
            }
            
        finally:
            if qemu_proc:
                try:
                    os.killpg(os.getpgid(qemu_proc.pid), signal.SIGTERM)
                    time.sleep(1)
                    if qemu_proc.poll() is None:
                        os.killpg(os.getpgid(qemu_proc.pid), signal.SIGKILL)
                except:
                    pass
    
    def boot_and_monitor_continuously(self, target_tier=3, wait_time=30):
        self.log(f"-> Booting to Tier {target_tier}...")
        
        start_time = time.time()
        output_lines = []
        tier_history = {}
        
        try:
            qemu_proc = subprocess.Popen(
                ["bash", BOOT_SCRIPT],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
                universal_newlines=True,
                preexec_fn=os.setsid
            )
            
            output_queue = queue.Queue()
            
            def reader_thread():
                try:
                    while True:
                        line = qemu_proc.stdout.readline()
                        if not line:
                            break
                        output_queue.put(line)
                except:
                    pass
            
            reader = threading.Thread(target=reader_thread, daemon=True)
            reader.start()
            
            target_reached_time = None
            last_log_time = time.time()
            
            while True:
                try:
                    while True:
                        line = output_queue.get_nowait()
                        output_lines.append(line.rstrip())
                        self.parse_tier_continuously([line], tier_history)
                except queue.Empty:
                    pass
                
                current_tier = tier_history[max(tier_history.keys())] if tier_history else 0
                
                if current_tier >= target_tier and target_reached_time is None:
                    target_reached_time = time.time()
                    elapsed = target_reached_time - start_time
                    self.log(f"   Tier {current_tier} reached at {elapsed:.1f}s")
                
                if target_reached_time and (time.time() - target_reached_time) >= wait_time:
                    self.log(f"   Waited {wait_time}s at Tier {current_tier}")
                    break
                
                if time.time() - start_time > self.timeout:
                    self.log(f"   Timeout - current tier: {current_tier}")
                    break
                
                if time.time() - last_log_time > 10:
                    elapsed = time.time() - start_time
                    self.log(f"  ... {elapsed:.0f}s, tier: {current_tier}, lines: {len(output_lines)}")
                    last_log_time = time.time()
                
                time.sleep(0.1)
            
            return qemu_proc, tier_history, output_lines
            
        except Exception as e:
            self.log(f"   Boot failed: {e}")
            if qemu_proc:
                try:
                    os.killpg(os.getpgid(qemu_proc.pid), signal.SIGKILL)
                except:
                    pass
            return None, tier_history, output_lines
    
    def clear_journal_recovery_blockers(self):
        journal_path = f"{FT}/var/pac/journal.dat"
        journal_tool = JOURNAL_TOOL  
        
        if not os.path.exists(journal_path) or not os.path.exists(journal_tool):
            return False
        
        try:
            flags_to_clear = ['emergency', 'dirty', 'quarantine']
            for flag in flags_to_clear:
                result = subprocess.run(
                    [journal_tool, "clear-flag", flag, journal_path],
                    capture_output=True, text=True, timeout=5
                )
            
            subprocess.run(
                [journal_tool, "reset-tries", journal_path],
                capture_output=True, text=True, timeout=5, check=False
            )
            
            return True
        except Exception as e:
            return False
    
    def rebuild_initramfs(self):
        try:
            rootfs_dir = f"{FT}/tier1_initramfs/rootfs"
            img_dir = f"{FT}/tier1_initramfs/img"
            result = subprocess.run(
                f"cd {rootfs_dir} && find . | cpio -o -H newc 2>/dev/null | gzip -9 > {img_dir}/initramfs.cpio.gz && cp {img_dir}/initramfs.cpio.gz {img_dir}/pac_initramfs.cpio.gz",
                shell=True, capture_output=True, timeout=30
            )
            if result.returncode == 0:
                self.log(f"   Initramfs rebuilt")
                return True
            else:
                self.log(f"   Initramfs rebuild may have failed")
                return False
        except Exception as e:
            self.log(f"   Initramfs rebuild failed: {e}")
            return False
    
    def inject_fault_before_boot(self, fault_type, **kwargs):
        self.log(f"-> Injecting {fault_type} fault before boot...")
        
        rootfs_journal = f"{FT}/tier1_initramfs/rootfs/var/pac/journal.dat"
        
        if fault_type == 'bit_flip':
            target = kwargs.get('target', rootfs_journal)
            self.log(f"-> Using CRC-targeted corruption (corrupts BOTH journal pages)")
            result = self.base_injector.inject_journal_crc_corruption(target)
            if result:
                self.log(f"-> Rebuilding initramfs with corrupted journal...")
                self.rebuild_initramfs()
            return result
        elif fault_type == 'torn_write':
            target = kwargs.get('target', rootfs_journal)
            result = self.base_injector.inject_torn_write(target, truncate_bytes=kwargs.get('truncate_bytes', random.randint(50, 65)))
            if result:
                self.log(f"-> Rebuilding initramfs with truncated journal...")
                self.rebuild_initramfs()
            return result
        elif fault_type == 'signature':
            target = kwargs.get('target', f"{FT}/boot/fit/fit.itb")
            if not os.path.exists(target):
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, 'wb') as f:
                    f.write(b'\x00' * 4096)
            return self.base_injector.inject_signature_corruption(target)
        elif fault_type == 'brownout':
            return self.base_injector.inject_brownout_flag()
        elif fault_type == 'ecc':
            count = kwargs.get('count', random.randint(11, 20))
            return self.base_injector.inject_ecc_error(count=count)
        elif fault_type == 'watchdog':
            return self.base_injector.inject_watchdog_fault()
        elif fault_type == 'temperature':
            temp = kwargs.get('temperature', random.randint(86, 95))
            return self.base_injector.inject_temperature_fault(temperature=temp)
        elif fault_type == 'storage':
            return self.base_injector.inject_storage_failure()
        else:
            self.log(f"   Unknown fault type: {fault_type}")
            return None
    
    def inject_runtime_fault(self, fault_type, qemu_proc=None, **kwargs):
        self.log(f"-> Injecting RUNTIME fault: {fault_type}")
        
        if fault_type == 'verifier_kill':
            subprocess.run(["pkill", "-9", "-f", "verifier.py"], capture_output=True, check=False)
            time.sleep(1)
            return {'type': 'verifier_kill', 'timestamp': time.time()}
        elif fault_type == 'verifier_restart':
            self.log(f"  -> Starting verifier service...")
            verifier_script = f"{FT}/verifier/verifier.py"
            subprocess.Popen(["python3", verifier_script], stdout=subprocess.DEVNULL, 
                           stderr=subprocess.DEVNULL, start_new_session=True)
            time.sleep(3)  
            if subprocess.run(["pgrep", "-f", "verifier.py"], capture_output=True).returncode == 0:
                self.log(f"   Verifier restarted successfully")
            else:
                self.log(f"   Verifier restart may have failed")
            return {'type': 'verifier_restart', 'timestamp': time.time()}
        
        runtime_compatible = ['ecc', 'watchdog', 'temperature', 'storage']
        if fault_type not in runtime_compatible:
            self.log(f"   '{fault_type}' is not runtime-compatible")
            return {'type': fault_type, 'error': 'not_runtime_compatible'}
        elif fault_type == 'ecc':
            count = kwargs.get('count', random.randint(11, 20))
            return self.base_injector.inject_ecc_error(count=count)
        elif fault_type == 'watchdog':
            return self.base_injector.inject_watchdog_fault()
        elif fault_type == 'temperature':
            temp = kwargs.get('temperature', random.randint(86, 95))
            return self.base_injector.inject_temperature_fault(temperature=temp)
        elif fault_type == 'storage':
            return self.base_injector.inject_storage_failure()
        else:
            return None
    
    def monitor_degradation(self, qemu_proc, initial_tier, monitor_duration=120):
        self.log(f"-> Monitoring degradation for {monitor_duration}s...")
        
        start_time = time.time()
        output_lines = []
        tier_history = {start_time: initial_tier}
        
        try:
            output_queue = queue.Queue()
            
            def reader_thread():
                try:
                    while True:
                        line = qemu_proc.stdout.readline()
                        if not line:
                            break
                        output_queue.put(line)
                except:
                    pass
            
            reader = threading.Thread(target=reader_thread, daemon=True)
            reader.start()
            
            last_log_time = time.time()
            
            while time.time() - start_time < monitor_duration:
                try:
                    while True:
                        line = output_queue.get_nowait()
                        output_lines.append(line.rstrip())
                        self.parse_tier_continuously([line], tier_history)
                except queue.Empty:
                    pass
                
                current_tier = tier_history[max(tier_history.keys())] if tier_history else initial_tier
                
                if time.time() - last_log_time > 10:
                    elapsed = time.time() - start_time
                    self.log(f"  ... {elapsed:.0f}s, tier: {current_tier}")
                    last_log_time = time.time()
                
                time.sleep(0.1)
            
            final_tier = tier_history[max(tier_history.keys())]
            degraded = final_tier < initial_tier
            
            mttd = None
            if len(tier_history) > 1:
                sorted_times = sorted(tier_history.keys())
                mttd = sorted_times[1] - sorted_times[0]
            
            self.log(f"  Monitoring complete: T{initial_tier}->T{final_tier}, MTTD: {mttd:.2f}s" if mttd else f"  Monitoring complete: T{initial_tier}->T{final_tier}")
            
            return {
                'initial_tier': initial_tier,
                'final_tier': final_tier,
                'degraded': degraded,
                'tier_history': tier_history,
                'mttd': mttd,
                'output_lines': len(output_lines)
            }
            
        except Exception as e:
            self.log(f"   Monitoring failed: {e}")
            return {
                'initial_tier': initial_tier,
                'final_tier': 0,
                'degraded': True,
                'error': str(e)
            }
    
    def run_single_trial(self, fault_type, trial_num, **kwargs):
        start_time = time.time()
        start_ts = datetime.now().strftime("%H:%M:%S")
        
        self.log(f"\n{'='*70}")
        self.log(f"BOOT-TIME TRIAL #{trial_num}: {fault_type.upper()}")
        self.log(f"{'='*70}")
        self.log(f"Started: {start_ts}")
        self.log(f"")
        
        self.log(f"[PHASE 1] System Cleanup")
        self.cleanup_system()
        self.base_injector.clear_fault_flags()
        self.log(f"   Cleanup complete")
        self.log(f"")
        
        self.log(f"[PHASE 2] Fault Injection: {fault_type}")
        fault_info = self.inject_fault_before_boot(fault_type, **kwargs)
        if isinstance(fault_info, dict):
            for key, value in fault_info.items():
                if key != 'timestamp':
                    self.log(f"  --- {key}: {value}")
        self.log(f"   Fault injected")
        self.log(f"")
        
        self.log(f"[PHASE 3] System Boot")
        if fault_type == 'power_cut':
            qemu_proc = subprocess.Popen(["bash", BOOT_SCRIPT], stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, preexec_fn=os.setsid)
            delay = kwargs.get('delay', random.uniform(2.0, 8.0))
            time.sleep(delay)
            self.log(f"   POWER CUT at {delay:.1f}s")
            try:
                os.killpg(os.getpgid(qemu_proc.pid), signal.SIGKILL)
            except:
                pass
            time.sleep(2)
            boot_result = self.boot_qemu_and_measure(monitor_duration=60)
        else:
            boot_result = self.boot_qemu_and_measure(monitor_duration=60)
        
        self.log(f"")
        self.log(f"[PHASE 4] Cleanup & Restore")
        self.base_injector.restore_all()
        self.base_injector.clear_fault_flags()
        self.log(f"   System restored")
        
        total_time = time.time() - start_time
        end_ts = datetime.now().strftime("%H:%M:%S")
        
        result = {
            'trial': trial_num,
            'fault_type': fault_type,
            'fault_info': fault_info,
            'tier_reached': boot_result['tier'],
            'boot_time': boot_result['boot_time'],
            'success': boot_result['success'],
            'recovered': boot_result['recovered'],
            'tier_timestamps': boot_result.get('tier_timestamps', {}),
            'total_trial_time': total_time,
            'timestamp': datetime.now().isoformat()
        }
        
        if boot_result.get('error'):
            result['error'] = boot_result['error']
        
        self.log(f"")
        self.log(f"{''*70}")
        self.log(f"TRIAL RESULT:")
        self.log(f"  Tier Reached:     {result['tier_reached']}")
        self.log(f"  Boot Time:        {result['boot_time']:.2f}s")
        self.log(f"  Success:          {'' if result['success'] else ''}")
        self.log(f"  Total Duration:   {total_time:.2f}s")
        self.log(f"  Completed:        {end_ts}")
        self.log(f"{''*70}")
        
        return result
    
    def run_runtime_trial(self, fault_type, trial_num, target_tier=3, test_recovery=False, **kwargs):
        start_time = time.time()
        start_ts = datetime.now().strftime("%H:%M:%S")
        
        self.log(f"\n{'='*70}")
        self.log(f"RUNTIME TRIAL #{trial_num}: {fault_type.upper()}")
        self.log(f"{'='*70}")
        self.log(f"Started: {start_ts}")
        self.log(f"Target Tier: {target_tier}")
        self.log(f"Recovery Test: {'Yes' if test_recovery else 'No'}")
        self.log(f"")
        
        self.log(f"[PHASE 1] System Cleanup")
        self.cleanup_system()
        self.base_injector.clear_fault_flags()
        self.log(f"   Cleanup complete")
        self.log(f"")
        
        self.log(f"[PHASE 2] Boot to Tier {target_tier}")
        qemu_proc, tier_history, output_lines = self.boot_and_monitor_continuously(
            target_tier=target_tier, wait_time=60
        )
        
        if not qemu_proc or not tier_history:
            self.log("   Boot failed")
            self.log(f"")
            return {'trial': trial_num, 'fault_type': fault_type, 'mode': 'runtime', 
                    'success': False, 'error': 'boot_failed'}
        
        initial_tier = tier_history[max(tier_history.keys())]
        boot_time = max(tier_history.keys()) - min(tier_history.keys())
        self.log(f"   Booted to Tier {initial_tier} in {boot_time:.1f}s")
        self.log(f"")
        
        self.log(f"[PHASE 3] Runtime Fault Injection: {fault_type}")
        fault_info = self.inject_runtime_fault(fault_type, qemu_proc=qemu_proc, **kwargs)
        if isinstance(fault_info, dict):
            for key, value in fault_info.items():
                if key not in ['timestamp', 'type']:
                    self.log(f"  --- {key}: {value}")
        self.log(f"   Fault injected, waiting 5s for detection...")
        time.sleep(5)  
        self.log(f"")
        
        self.log(f"[PHASE 4] Monitor System Degradation (120s)")
        degradation_result = self.monitor_degradation(qemu_proc, initial_tier, monitor_duration=120)
        self.log(f"  Initial Tier: {initial_tier}")
        self.log(f"  Final Tier:   {degradation_result['final_tier']}")
        self.log(f"  Degraded:     {' Yes' if degradation_result['degraded'] else ' No'}")
        if degradation_result.get('mttd'):
            self.log(f"  MTTD:         {degradation_result['mttd']:.2f}s")
        self.log(f"")
        
        recovery_result = None
        if test_recovery and fault_type in ['verifier_kill', 'ecc', 'watchdog', 'temperature', 'storage']:
            self.log(f"[PHASE 5] Recovery Testing")
            
            if fault_type == 'verifier_kill':
                self.log(f"  --- Restarting verifier...")
                self.inject_runtime_fault('verifier_restart')
                recovery_duration = 120  
            else:
                self.log(f"  --- Clearing fault condition...")
                self.base_injector.clear_fault_flags()
                self.log(f"  --- Clearing journal recovery blockers...")
                self.clear_journal_recovery_blockers()
                self.log(f"  --- Hardware faults need longer recovery time (post-reboot stabilization)...")
                recovery_duration = 180  
            
            self.log(f"  --- Monitoring recovery ({recovery_duration}s)...")
            recovery_result = self.monitor_degradation(qemu_proc, degradation_result['final_tier'], 
                                                      monitor_duration=recovery_duration)
            
            if recovery_result['final_tier'] > degradation_result['final_tier']:
                mttr = None
                if len(recovery_result['tier_history']) > 1:
                    sorted_times = sorted(recovery_result['tier_history'].keys())
                    mttr = sorted_times[-1] - sorted_times[0]
                recovery_result['mttr'] = mttr
                self.log(f"   Recovery: T{degradation_result['final_tier']}->T{recovery_result['final_tier']}")
                if mttr:
                    self.log(f"    MTTR: {mttr:.2f}s")
            else:
                self.log(f"   No recovery to higher tier within {recovery_duration}s")
                self.log(f"    (Conservative policy may require manual intervention or extended clean operation)")
            self.log(f"")
        
        phase_num = 6 if test_recovery else 5
        self.log(f"[PHASE {phase_num}] Cleanup & Restore")
        try:
            os.killpg(os.getpgid(qemu_proc.pid), signal.SIGTERM)
            time.sleep(1)
            if qemu_proc.poll() is None:
                os.killpg(os.getpgid(qemu_proc.pid), signal.SIGKILL)
        except:
            pass
        
        self.base_injector.restore_all()
        self.base_injector.clear_fault_flags()
        self.log(f"   System restored")
        
        if fault_type == 'verifier_kill':
            self.log(f"   Restarting verifier for next trial...")
            self.inject_runtime_fault('verifier_restart')
        
        total_time = time.time() - start_time
        end_ts = datetime.now().strftime("%H:%M:%S")
        
        result = {
            'trial': trial_num,
            'fault_type': fault_type,
            'mode': 'runtime',
            'target_tier': target_tier,
            'initial_tier': initial_tier,
            'final_tier': degradation_result['final_tier'],
            'degraded': degradation_result['degraded'],
            'boot_time': boot_time,
            'mttd': degradation_result.get('mttd'),
            'tier_history': {str(k): v for k, v in tier_history.items()},
            'fault_info': fault_info,
            'total_trial_time': total_time,
            'success': True,
            'timestamp': datetime.now().isoformat()
        }
        
        if recovery_result:
            result['recovery'] = {
                'recovered': recovery_result['final_tier'] > degradation_result['final_tier'],
                'recovery_tier': recovery_result['final_tier'],
                'mttr': recovery_result.get('mttr')
            }
        
        self.log(f"")
        self.log(f"{''*70}")
        self.log(f"TRIAL RESULT:")
        self.log(f"  Initial Tier:     {initial_tier}")
        self.log(f"  Final Tier:       {degradation_result['final_tier']}")
        self.log(f"  Degraded:         {' Yes' if degradation_result['degraded'] else ' No'}")
        if degradation_result.get('mttd'):
            self.log(f"  MTTD:             {degradation_result['mttd']:.2f}s")
        if recovery_result and recovery_result.get('mttr'):
            self.log(f"  Recovery:          Yes (T{degradation_result['final_tier']}->T{recovery_result['final_tier']})")
            self.log(f"  MTTR:             {recovery_result['mttr']:.2f}s")
        self.log(f"  Total Duration:   {total_time:.2f}s")
        self.log(f"  Completed:        {end_ts}")
        self.log(f"{''*70}")
        
        return result
    
    def run_campaign(self, fault_type, iterations=50, runtime=False, recovery=False, trial_delay=5, **kwargs):
        campaign_start = time.time()
        start_ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        mode_str = "RUNTIME" if runtime else "BOOT-TIME"
        recovery_str = " WITH RECOVERY" if recovery else ""
        
        self.log(f"\n")
        self.log(f"{''*68}")
        self.log(f"  {mode_str}{recovery_str} CAMPAIGN: {fault_type.upper():^{58-len(mode_str)-len(recovery_str)}}  ")
        self.log(f"{''*68}")
        self.log(f"Started:    {start_ts}")
        self.log(f"Iterations: {iterations}")
        self.log(f"Mode:       {mode_str}{recovery_str}")
        self.log(f"Fault:      {fault_type}")
        
        if not runtime:  
            self.log(f"")
            self.log(f"[CAMPAIGN INIT] Resetting journal to clean state...")
            self.reset_journal_to_clean_state()
            self.rebuild_initramfs()
            self.log(f"   Campaign initialized with clean state")
        
        self.log(f"")
        
        results = []
        success_count = 0
        
        for i in range(iterations):
            trial_start = time.time()
            
            if runtime:
                result = self.run_runtime_trial(fault_type, i + 1, test_recovery=recovery, **kwargs)
            else:
                result = self.run_single_trial(fault_type, i + 1, **kwargs)
            
            results.append(result)
            
            if result.get('success'):
                success_count += 1
            
            trial_time = time.time() - trial_start
            elapsed = time.time() - campaign_start
            remaining = (elapsed / (i + 1)) * (iterations - (i + 1))
            
            self.log(f"")
            self.log(f"Campaign Progress: {i+1}/{iterations} trials complete")
            self.log(f"  Success Rate:  {success_count}/{i+1} ({100*success_count/(i+1):.1f}%)")
            self.log(f"  Trial Time:    {trial_time:.1f}s")
            self.log(f"  Elapsed:       {elapsed/60:.1f} min")
            self.log(f"  Est. Remaining: {remaining/60:.1f} min")
            self.log(f"")
            
            if i < iterations - 1:
                time.sleep(trial_delay)
        
        success_rate = (success_count / iterations) * 100 if iterations > 0 else 0
        
        tier_distribution = {0: 0, 1: 0, 2: 0, 3: 0}
        for result in results:
            tier = result.get('final_tier' if runtime else 'tier_reached', 0)
            if tier in tier_distribution:
                tier_distribution[tier] += 1
        
        summary = {
            'fault_type': fault_type,
            'mode': 'runtime' if runtime else 'boot',
            'total_trials': iterations,
            'successful': success_count,
            'failed': iterations - success_count,
            'success_rate': f"{success_rate:.2f}%",
            'tier_distribution': tier_distribution
        }
        
        if runtime:
            degraded_count = sum(1 for r in results if r.get('degraded'))
            mttd_values = [r['mttd'] for r in results if r.get('mttd') is not None]
            avg_mttd = sum(mttd_values) / len(mttd_values) if mttd_values else None
            
            summary['degraded_count'] = degraded_count
            summary['degradation_rate'] = f"{(degraded_count/iterations*100):.2f}%"
            summary['avg_mttd'] = f"{avg_mttd:.3f}s" if avg_mttd else "N/A"
            
            if recovery:
                recovery_count = sum(1 for r in results if r.get('recovery', {}).get('recovered'))
                mttr_values = [r['recovery']['mttr'] for r in results if r.get('recovery', {}).get('mttr')]
                avg_mttr = sum(mttr_values) / len(mttr_values) if mttr_values else None
                
                summary['recovery_count'] = recovery_count
                summary['recovery_rate'] = f"{(recovery_count/iterations*100):.2f}%"
                summary['avg_mttr'] = f"{avg_mttr:.3f}s" if avg_mttr else "N/A"
        else:
            avg_boot_time = sum(r['boot_time'] for r in results) / len(results) if results else 0
            summary['avg_boot_time'] = f"{avg_boot_time:.3f}s"
        
        campaign_time = time.time() - campaign_start
        end_ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        self.log(f"\n")
        self.log(f"{''*68}")
        self.log(f"  CAMPAIGN COMPLETE: {fault_type.upper():^48}  ")
        self.log(f"{''*68}")
        self.log(f"")
        self.log(f"SUMMARY:")
        self.log(f"  Fault Type:       {fault_type}")
        self.log(f"  Mode:             {mode_str}{recovery_str}")
        self.log(f"  Total Trials:     {iterations}")
        self.log(f"  Successful:       {success_count}")
        self.log(f"  Failed:           {iterations - success_count}")
        self.log(f"  Success Rate:     {summary['success_rate']}")
        self.log(f"")
        
        if runtime:
            self.log(f"DEGRADATION ANALYSIS:")
            self.log(f"  Degraded Count:   {summary['degraded_count']}")
            self.log(f"  Degradation Rate: {summary['degradation_rate']}")
            self.log(f"  Avg MTTD:         {summary['avg_mttd']}")
            
            if mttd_values:
                self.log(f"  Min MTTD:         {min(mttd_values):.3f}s")
                self.log(f"  Max MTTD:         {max(mttd_values):.3f}s")
            self.log(f"")
            
            if recovery:
                self.log(f"RECOVERY ANALYSIS:")
                self.log(f"  Recovery Count:   {summary['recovery_count']}")
                self.log(f"  Recovery Rate:    {summary['recovery_rate']}")
                self.log(f"  Avg MTTR:         {summary['avg_mttr']}")
                if mttr_values:
                    self.log(f"  Min MTTR:         {min(mttr_values):.3f}s")
                    self.log(f"  Max MTTR:         {max(mttr_values):.3f}s")
                self.log(f"")
        else:
            self.log(f"BOOT ANALYSIS:")
            self.log(f"  Avg Boot Time:    {summary['avg_boot_time']}")
            boot_times = [r['boot_time'] for r in results if r.get('boot_time')]
            if boot_times:
                self.log(f"  Min Boot Time:    {min(boot_times):.3f}s")
                self.log(f"  Max Boot Time:    {max(boot_times):.3f}s")
            self.log(f"")
        
        self.log(f"TIER DISTRIBUTION:")
        for tier in [0, 1, 2, 3]:
            count = tier_distribution.get(tier, 0)
            pct = (count / iterations * 100) if iterations > 0 else 0
            self.log(f"  Tier {tier}:           {count:3d} ({pct:5.1f}%)")
        self.log(f"")
        
        self.log(f"TIMING:")
        self.log(f"  Started:          {start_ts}")
        self.log(f"  Completed:        {end_ts}")
        self.log(f"  Total Duration:   {campaign_time/60:.1f} minutes ({campaign_time:.1f}s)")
        self.log(f"  Avg Trial Time:   {campaign_time/iterations:.1f}s")
        self.log(f"")
        self.log(f"{''*70}\n")
        
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"qemu_results_{fault_type}_{'runtime' if runtime else 'boot'}_{timestamp}.json"
        filepath = os.path.join(RESULTS_DIR, filename)
        
        output = {
            'metadata': {
                'experiment': 'PAC Fault Injection',
                'fault_type': fault_type,
                'mode': 'runtime' if runtime else 'boot',
                'timestamp': datetime.now().isoformat()
            },
            'summary': summary,
            'results': results
        }
        
        with open(filepath, 'w') as f:
            json.dump(output, f, indent=2)
        
        latest_file = os.path.join(RESULTS_DIR, f"qemu_results_{fault_type}_{'runtime' if runtime else 'boot'}_latest.json")
        with open(latest_file, 'w') as f:
            json.dump(output, f, indent=2)
        
        self.log(f" Results saved: {filename}")
        
        return results, summary

class ExperimentOrchestrator:
    
    def __init__(self, verbose=True, trial_delay=5):
        self.verbose = verbose
        self.trial_delay = trial_delay
        self.injector = None
        self.verifier_started = False
        self.overall_start_time = None
        self.campaign_summaries = []
    
    def log(self, message):
        if self.verbose:
            print(message)
    
    def ensure_verifier_running(self):
        if subprocess.run(["pgrep", "-f", "verifier.py"], capture_output=True).returncode != 0:
            self.log("-> Starting verifier...")
            verifier_script = f"{FT}/verifier/verifier.py"
            subprocess.Popen(["python3", verifier_script], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, start_new_session=True)
            time.sleep(3)
            
            if subprocess.run(["pgrep", "-f", "verifier.py"], capture_output=True).returncode == 0:
                self.log("   Verifier started")
                self.verifier_started = True
                return True
            else:
                self.log("   Failed to start verifier")
                return False
        else:
            self.log(" Verifier already running")
            return True
    
    def stop_verifier_if_started(self):
        if self.verifier_started:
            self.log("-> Stopping verifier...")
            subprocess.run(["pkill", "-f", "verifier.py"], check=False)
            self.log("   Verifier stopped")
    
    def print_overall_summary(self, mode, iterations):
        if not self.overall_start_time:
            return
        
        total_time = time.time() - self.overall_start_time
        end_ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        self.log(f"\n")
        self.log(f"{''*68}")
        self.log(f"  OVERALL EXPERIMENT SUMMARY{' '*40}")
        self.log(f"{''*68}")
        self.log(f"")
        self.log(f"CONFIGURATION:")
        self.log(f"  Mode:             {mode.upper()}")
        self.log(f"  Trials per Fault: {iterations}")
        self.log(f"")
        
        total_campaigns = 0
        total_trials = 0
        successful_trials = 0
        
        result_files = glob.glob(f"{RESULTS_DIR}/qemu_results_*.json")
        recent_files = sorted(result_files, key=os.path.getmtime, reverse=True)
        
        self.log(f"CAMPAIGNS COMPLETED:")
        for result_file in recent_files[:20]:  
            try:
                with open(result_file, 'r') as f:
                    data = json.load(f)
                    if 'summary' in data:
                        total_campaigns += 1
                        summary = data['summary']
                        fault = summary.get('fault_type', 'unknown')
                        mode_str = summary.get('mode', 'unknown')
                        trials = summary.get('total_trials', 0)
                        success = summary.get('successful', 0)
                        
                        total_trials += trials
                        successful_trials += success
                        
                        success_rate = summary.get('success_rate', 'N/A')
                        self.log(f"  --- {fault:15s} ({mode_str:8s}): {success}/{trials} trials, {success_rate}")
            except:
                pass
        
        if total_campaigns > 0:
            self.log(f"")
            self.log(f"TOTALS:")
            self.log(f"  Campaigns:        {total_campaigns}")
            self.log(f"  Total Trials:     {total_trials}")
            self.log(f"  Successful:       {successful_trials}")
            self.log(f"  Failed:           {total_trials - successful_trials}")
            if total_trials > 0:
                self.log(f"  Overall Success:  {100*successful_trials/total_trials:.1f}%")
        
        self.log(f"")
        self.log(f"DURATION:")
        self.log(f"  Completed:        {end_ts}")
        self.log(f"  Total Time:       {total_time/3600:.2f} hours ({total_time/60:.1f} minutes)")
        if total_trials > 0:
            self.log(f"  Avg per Trial:    {total_time/total_trials:.1f}s")
        self.log(f"")
        self.log(f"RESULTS LOCATION:")
        self.log(f"  {RESULTS_DIR}/")
        self.log(f"")
        self.log(f"{''*70}\n")
    
    def run_mode(self, mode, iterations):
        self.overall_start_time = time.time()
        start_ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        self.log(f"\n")
        self.log(f"{''*68}")
        self.log(f"  PAC FAULT INJECTION EXPERIMENTS{' '*23}")
        self.log(f"{''*68}")
        self.log(f"")
        self.log(f"EXPERIMENT CONFIGURATION:")
        self.log(f"  Mode:             {mode.upper()}")
        self.log(f"  Trials per Fault: {iterations}")
        self.log(f"  Trial Delay:      {self.trial_delay}s")
        self.log(f"  Started:          {start_ts}")
        self.log(f"")
        
        if not self.ensure_verifier_running():
            self.log("ERROR: Verifier required but failed to start")
            return
        
        self.injector = QEMUFaultInjector(verbose=self.verbose, timeout=240)
        
        if mode == 'boot':
            self.run_boot_campaigns(iterations)
        elif mode == 'runtime':
            self.run_runtime_campaigns(iterations, recovery=False)
        elif mode == 'recovery':
            self.run_runtime_campaigns(iterations, recovery=True)
        elif mode == 'chaos':
            self.run_chaos_experiments(iterations)
        elif mode == 'all':
            self.run_boot_campaigns(iterations)
            self.run_runtime_campaigns(iterations, recovery=False)
            self.run_runtime_campaigns(iterations, recovery=True)
        elif mode == 'quick':
            self.run_boot_campaigns(3)
            self.run_runtime_campaigns(3, recovery=False)
        
        self.print_overall_summary(mode, iterations)
    
    def run_boot_campaigns(self, iterations):
        start_time = time.time()
        
        self.log(f"\n")
        self.log(f"{''*68}")
        self.log(f"  BOOT-TIME FAULT INJECTION CAMPAIGNS{' '*31}")
        self.log(f"{''*68}")
        self.log(f"")
        self.log(f"Fault Types: {', '.join(BOOT_TIME_FAULTS)}")
        self.log(f"Total Campaigns: {len(BOOT_TIME_FAULTS)}")
        self.log(f"Trials Each: {iterations}")
        self.log(f"")
        
        self.injector.cleanup_system()
        
        for i, fault in enumerate(BOOT_TIME_FAULTS, 1):
            self.log(f"[CAMPAIGN {i}/{len(BOOT_TIME_FAULTS)}] Starting {fault} campaign...")
            self.injector.run_campaign(fault, iterations=iterations, runtime=False, trial_delay=self.trial_delay)
            time.sleep(self.trial_delay)
        
        elapsed = time.time() - start_time
        self.log(f"\n")
        self.log(f"Boot-time campaigns complete: {len(BOOT_TIME_FAULTS)} campaigns, {len(BOOT_TIME_FAULTS)*iterations} trials, {elapsed/60:.1f} minutes")
        self.log(f"")
    
    def run_runtime_campaigns(self, iterations, recovery=False):
        start_time = time.time()
        
        mode_str = "WITH RECOVERY" if recovery else "DEGRADATION"
        self.log(f"\n")
        self.log(f"{''*68}")
        self.log(f"  RUNTIME FAULT INJECTION - {mode_str}{' '*(42-len(mode_str))}")
        self.log(f"{''*68}")
        self.log(f"")
        self.log(f"Fault Types: {', '.join(RUNTIME_FAULTS)}")
        self.log(f"Total Campaigns: {len(RUNTIME_FAULTS)}")
        self.log(f"Trials Each: {iterations}")
        self.log(f"Recovery Test: {'Yes' if recovery else 'No'}")
        self.log(f"")
        
        self.injector.cleanup_system()
        
        self.log(f"[RUNTIME INIT] Preparing clean state for Tier 3 boot...")
        self.injector.reset_journal_to_clean_state()
        self.injector.rebuild_initramfs()
        self.log(f"   Ready for runtime campaigns")
        
        for i, fault in enumerate(RUNTIME_FAULTS, 1):
            self.log(f"[CAMPAIGN {i}/{len(RUNTIME_FAULTS)}] Starting {fault} campaign...")
            self.injector.run_campaign(fault, iterations=iterations, runtime=True, recovery=recovery, trial_delay=self.trial_delay)
            time.sleep(self.trial_delay)
        
        elapsed = time.time() - start_time
        self.log(f"\n")
        self.log(f"Runtime campaigns complete: {len(RUNTIME_FAULTS)} campaigns, {len(RUNTIME_FAULTS)*iterations} trials, {elapsed/60:.1f} minutes")
        self.log(f"")
    
    def run_chaos_experiments(self, iterations):
        self.log("\n")
        self.log("                    CHAOS MODE EXPERIMENTS                         ")
        self.log("\n")
        
        results = []
        
        for trial in range(iterations):
            self.log(f"\n{'='*70}")
            self.log(f"CHAOS TRIAL {trial + 1}/{iterations}")
            self.log(f"{'='*70}")
            
            scenario = random.choice(['boot_fault_only', 'runtime_single', 'runtime_cascade'])
            self.log(f"Scenario: {scenario}")
            
            self.injector.cleanup_system()
            
            trial_result = {
                'trial': trial + 1,
                'scenario': scenario,
                'faults_injected': [],
                'timestamp': datetime.now().isoformat()
            }
            
            try:
                if scenario == 'boot_fault_only':
                    boot_fault = random.choice(BOOT_TIME_FAULTS)
                    self.log(f"  -> Boot fault: {boot_fault}")
                    self.injector.inject_fault_before_boot(boot_fault)
                    trial_result['faults_injected'].append(boot_fault)
                    
                    boot_result = self.injector.boot_qemu_and_measure(monitor_duration=90)
                    trial_result['final_tier'] = boot_result['tier']
                    trial_result['success'] = boot_result['success']
                
                elif scenario == 'runtime_single':
                    self.log(f"  -> Booting to Tier 3...")
                    qemu_proc, tier_history, _ = self.injector.boot_and_monitor_continuously(3, 20)
                    
                    if qemu_proc:
                        initial_tier = tier_history[max(tier_history.keys())]
                        runtime_fault = random.choice(RUNTIME_FAULTS)
                        self.log(f"  -> Runtime fault: {runtime_fault}")
                        self.injector.inject_runtime_fault(runtime_fault)
                        trial_result['faults_injected'].append(runtime_fault)
                        
                        degrade_result = self.injector.monitor_degradation(qemu_proc, initial_tier, 60)
                        trial_result['initial_tier'] = initial_tier
                        trial_result['final_tier'] = degrade_result['final_tier']
                        
                        os.killpg(os.getpgid(qemu_proc.pid), signal.SIGKILL)
                
                elif scenario == 'runtime_cascade':
                    self.log(f"  -> Booting to Tier 3...")
                    qemu_proc, tier_history, _ = self.injector.boot_and_monitor_continuously(3, 20)
                    
                    if qemu_proc:
                        initial_tier = tier_history[max(tier_history.keys())]
                        num_faults = random.randint(2, 3)
                        self.log(f"  -> Injecting {num_faults} cascading faults...")
                        
                        for i in range(num_faults):
                            fault = random.choice(RUNTIME_FAULTS)
                            self.log(f"    {i+1}. {fault}")
                            self.injector.inject_runtime_fault(fault)
                            trial_result['faults_injected'].append(fault)
                            time.sleep(random.randint(10, 20))
                        
                        degrade_result = self.injector.monitor_degradation(qemu_proc, initial_tier, 60)
                        trial_result['initial_tier'] = initial_tier
                        trial_result['final_tier'] = degrade_result['final_tier']
                        
                        os.killpg(os.getpgid(qemu_proc.pid), signal.SIGKILL)
                
                self.injector.base_injector.restore_all()
                self.injector.base_injector.clear_fault_flags()
                
                self.log(f" Chaos trial complete: {trial_result.get('faults_injected', [])}")
                
            except Exception as e:
                self.log(f" Chaos trial failed: {e}")
                trial_result['error'] = str(e)
            
            results.append(trial_result)
        
        output_file = os.path.join(RESULTS_DIR, f"qemu_results_chaos_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json")
        with open(output_file, 'w') as f:
            json.dump({
                'metadata': {'experiment': 'PAC Chaos Fault Injection', 'timestamp': datetime.now().isoformat()},
                'summary': {'fault_type': 'chaos', 'total_trials': iterations},
                'results': results
            }, f, indent=2)
        
        self.log(f"\n Chaos experiments complete: {output_file}")

def main():
    parser = argparse.ArgumentParser(
        description='PAC UNIFIED Fault Injection Framework',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  %(prog)s --fault bit_flip --trials 50 --trial-delay 10
  %(prog)s --fault ecc --trials 50 --trial-delay 15
  
  %(prog)s --mode boot --trials 50 --trial-delay 10
  %(prog)s --mode runtime --trials 50 --trial-delay 15
  %(prog)s --mode all --trials 50 --trial-delay 15
  %(prog)s --mode quick  
  
  %(prog)s --fault temperature --trials 20 --target-tier 2 --timeout 300
  %(prog)s --mode chaos --trials 30  

Fault Types:
  Boot-time: bit_flip, torn_write, signature, brownout, power_cut
  Runtime:   verifier_kill, ecc, watchdog, temperature, storage
  
Modes:
  boot     - All boot-time faults (bit_flip, torn_write, etc.)
  runtime  - All runtime degradation tests (ecc, watchdog, etc.)
  recovery - Runtime faults with recovery verification
  all      - Complete experiments (boot + runtime + recovery)
  quick    - Fast validation (3 trials per fault)
  chaos    - Random fault combinations
        '''
    )
    
    parser.add_argument('--fault', 
                       choices=ALL_FAULTS, 
                       help='Single fault type to test')
    
    parser.add_argument('--mode', 
                       choices=['boot', 'runtime', 'recovery', 'all', 'quick', 'chaos'],
                       help='Run experiment campaign mode')
    
    parser.add_argument('--trials', 
                       type=int, 
                       default=1, 
                       help='Number of trials per fault (default: 1)')
    
    parser.add_argument('--trial-delay', 
                       type=int, 
                       default=5, 
                       help='Delay between trials in seconds (default: 5)')
    
    parser.add_argument('--target-tier', 
                       type=int, 
                       default=3, 
                       help='Target tier for boot (default: 3)')
    
    parser.add_argument('--timeout', 
                       type=int, 
                       default=180, 
                       help='Boot timeout in seconds (default: 180)')
    
    parser.add_argument('--test-recovery',
                       action='store_true',
                       help='Test fault recovery (only for runtime faults with --fault)')
    
    parser.add_argument('--quiet', 
                       action='store_true', 
                       help='Minimal output')
    
    args = parser.parse_args()
    
    verbose = not args.quiet
    
    if args.fault and args.mode:
        print("ERROR: Cannot use --fault and --mode together. Choose one.")
        parser.print_help()
        sys.exit(1)
    
    if args.mode:
        orchestrator = ExperimentOrchestrator(verbose=verbose, trial_delay=args.trial_delay)
        iterations = args.trials if args.mode != 'quick' else 3
        orchestrator.run_mode(args.mode, iterations)
        orchestrator.stop_verifier_if_started()
        return
    
    if args.fault:
        is_runtime = args.fault in RUNTIME_FAULTS
        
        if args.test_recovery and not is_runtime:
            print(f"ERROR: --test-recovery only works with runtime faults, not '{args.fault}'")
            sys.exit(1)
        
        injector = QEMUFaultInjector(verbose=verbose, timeout=args.timeout, runtime_mode=is_runtime)
        
        for i in range(args.trials):
            if i > 0:
                time.sleep(args.trial_delay)
            
            if is_runtime:
                result = injector.run_runtime_trial(args.fault, i + 1, target_tier=args.target_tier, 
                                                    test_recovery=args.test_recovery)
                print(f"\nResult: T{result.get('initial_tier', '?')}->T{result.get('final_tier', '?')}, MTTD: {result.get('mttd', 'N/A')}")
            else:
                result = injector.run_single_trial(args.fault, i + 1)
                print(f"\nResult: Tier {result['tier_reached']}, Time: {result['boot_time']:.2f}s")
        
        return
    
    parser.print_help()


if __name__ == '__main__':
    main()
