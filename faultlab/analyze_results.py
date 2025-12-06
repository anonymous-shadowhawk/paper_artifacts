#!/usr/bin/env python3
import json
import glob
import sys
from pathlib import Path

FT = Path.home() / "ft-pac"
RESULTS_DIR = FT / "faultlab" / "results"

def analyze_results():
    
    
    results_files = sorted(glob.glob(str(RESULTS_DIR / "qemu_results_*_latest.json")))
    
    if not results_files:
        print("No results found. Run experiments first:")
        print("  python3 qemu_fault_injector.py --all --iterations 50")
        return
    
    print("")
    print("     PAC Fault Injection Results Summary                           ")
    print("")
    print()

    all_summaries = []
    
    for result_file in results_files:
        with open(result_file) as f:
            data = json.load(f)
        
        summary = data['summary']
        fault_type = summary['fault_type']
        mode = summary.get('mode', 'boot')
        
        all_summaries.append(summary)
        
        print(f" {fault_type.upper()} {'[RUNTIME]' if mode == 'runtime' else '[BOOT]'} ")
        print(f"  Total trials:    {summary['total_trials']}")
        print(f"  Success rate:    {summary['success_rate']}")
        
        if mode == 'runtime':
            print(f"  Degradation rate: {summary.get('degradation_rate', 'N/A')}")
            print(f"  Avg MTTD:        {summary.get('avg_mttd', 'N/A')}")
            if 'recovery_rate' in summary:
                print(f"  Recovery rate:   {summary['recovery_rate']}")
                print(f"  Avg MTTR:        {summary.get('avg_mttr', 'N/A')}")
        else:
            print(f"  Avg boot time:   {summary['avg_boot_time']}")
        
        print(f"  Tier distribution:")
        tier_dist = summary['tier_distribution']
        for tier_key in sorted([int(k) if isinstance(k, str) else k for k in tier_dist.keys()]):
            tier_str = str(tier_key)
            count = tier_dist.get(tier_str, tier_dist.get(tier_key, 0))
            pct = (count / summary['total_trials'] * 100) if summary['total_trials'] > 0 else 0
            print(f"    Tier {tier_key}: {count:3d} ({pct:5.1f}%)")
        print()
    
    if all_summaries:
        print("")
        print("OVERALL STATISTICS")
        print("")
        
        total_trials = sum(s['total_trials'] for s in all_summaries)
        total_success = sum(s['successful'] for s in all_summaries)
        
        if total_trials > 0:
            overall_success_rate = (total_success / total_trials) * 100
            print(f"  Total trials across all faults: {total_trials}")
            print(f"  Total successful boots:         {total_success}")
            print(f"  Overall success rate:           {overall_success_rate:.2f}%")
            print()
            
            boot_times = [float(s['avg_boot_time'].replace('s', '')) for s in all_summaries if 'avg_boot_time' in s]
            if boot_times:
                avg_boot_time = sum(boot_times) / len(boot_times)
                print(f"  Average boot time (boot faults): {avg_boot_time:.3f}s")
                print()
            
            print(f" System Availability: {overall_success_rate:.1f}%")
            print()

def export_latex_table():
    
    
    results_files = sorted(glob.glob(str(RESULTS_DIR / "qemu_results_*_latest.json")))
    
    if not results_files:
        print("No results found.")
        return
    
    boot_results = []
    runtime_results = []
    
    for result_file in results_files:
        with open(result_file) as f:
            data = json.load(f)
        summary = data['summary']
        mode = summary.get('mode', 'boot')
        
        if mode == 'runtime':
            runtime_results.append((result_file, data))
        else:
            boot_results.append((result_file, data))
    
    if boot_results:
        print("% Boot-time Fault Injection Results")
        print("\\begin{tabular}{lrrrrr}")
        print("\\toprule")
        print("Fault Type & Trials & Success & Rate (\\%) & Avg Boot Time (s) & Tier 3 (\\%) \\\\")
        print("\\midrule")
        
        for result_file, data in boot_results:
            summary = data['summary']
            fault_type = summary['fault_type'].replace('_', '\\_')
            trials = summary['total_trials']
            success = summary['successful']
            rate = float(summary['success_rate'].replace('%', ''))
            boot_time = summary.get('avg_boot_time', 'N/A').replace('s', '')
            
            tier_dist = summary['tier_distribution']
            tier3_count = tier_dist.get('3', tier_dist.get(3, 0))
            tier3_pct = (tier3_count / trials * 100) if trials > 0 else 0
            
            print(f"{fault_type} & {trials} & {success} & {rate:.1f} & {boot_time} & {tier3_pct:.1f} \\\\")
        
        print("\\bottomrule")
        print("\\end{tabular}")
        print()
    
    if runtime_results:
        print("% Runtime Fault Injection Results")
        print("\\begin{tabular}{lrrrrrr}")
        print("\\toprule")
        print("Fault Type & Trials & Success (\\%) & Degraded (\\%) & MTTD (s) & Recovery (\\%) & MTTR (s) \\\\")
        print("\\midrule")
        
        for result_file, data in runtime_results:
            summary = data['summary']
            fault_type = summary['fault_type'].replace('_', '\\_')
            trials = summary['total_trials']
            success_rate = float(summary['success_rate'].replace('%', ''))
            degrade_rate = float(summary.get('degradation_rate', '0%').replace('%', ''))
            mttd = summary.get('avg_mttd', 'N/A').replace('s', '')
            recovery_rate = summary.get('recovery_rate', 'N/A').replace('%', '') if 'recovery_rate' in summary else '--'
            mttr = summary.get('avg_mttr', 'N/A').replace('s', '') if 'avg_mttr' in summary else '--'
            
            print(f"{fault_type} & {trials} & {success_rate:.1f} & {degrade_rate:.1f} & {mttd} & {recovery_rate} & {mttr} \\\\")
        
        print("\\bottomrule")
        print("\\end{tabular}")

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--latex':
        export_latex_table()
    else:
        analyze_results()

