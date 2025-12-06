<div align="center">

<h1>
  <br>
  Progressive Attestation Chain (PAC) Boot System
  <br>
</h1>

<h4>Fault-Tolerant Secure Boot with Progressive Attestation</h4>

<br>

<p align="center">
  <a href="https://github.com/anonymous-shadowhawk/paper_artifacts/actions/workflows/build.yml">
    <img src="https://github.com/anonymous-shadowhawk/paper_artifacts/actions/workflows/build.yml/badge.svg?style=flat-square" alt="Build Status" height="30"/>
  </a>
  &nbsp;&nbsp;
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/LICENSE-MIT-00bcd4.svg?style=flat-square" alt="License" height="30"/>
  </a>
  &nbsp;&nbsp;
  <a href="https://www.qemu.org/">
    <img src="https://img.shields.io/badge/PLATFORM-ARM64%20%7C%20QEMU-1e88e5.svg?style=flat-square&logo=qemu&logoColor=white" alt="Platform" height="30"/>
  </a>
  &nbsp;&nbsp;
  <a href="https://trustedcomputinggroup.org/">
    <img src="https://img.shields.io/badge/TPM-2.0-e53935.svg?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJ3aGl0ZSI+PHBhdGggZD0iTTEyIDJDNi40OCAyIDIgNi40OCAyIDEyczQuNDggMTAgMTAgMTAgMTAtNC40OCAxMC0xMFMxNy41MiAyIDEyIDJ6bTAgMThjLTQuNDEgMC04LTMuNTktOC04czMuNTktOCA4LTggOCAzLjU5IDggOC0zLjU5IDgtOCA4em0wLTE0Yy0zLjMxIDAtNiAyLjY5LTYgNnMyLjY5IDYgNiA2IDYtMi42OSA2LTYtMi42OS02LTYtNnoiLz48L3N2Zz4=" alt="TPM" height="30"/>
  </a>
</p>

<p align="center">
  <a href="https://github.com/anonymous-shadowhawk/paper_artifacts">
    <img src="https://img.shields.io/badge/LANGUAGE-C%20%7C%20Python%20%7C%20Shell-43a047.svg?style=flat-square&logo=gnu&logoColor=white" alt="Languages" height="30"/>
  </a>
  &nbsp;&nbsp;
  <a href="https://ubuntu.com/">
    <img src="https://img.shields.io/badge/UBUNTU-22.04%20LTS-f57c00.svg?style=flat-square&logo=ubuntu&logoColor=white" alt="Ubuntu" height="30"/>
  </a>
  &nbsp;&nbsp;
  <img src="https://img.shields.io/badge/ARCHITECTURE-aarch64-7b1fa2.svg?style=flat-square&logo=arm&logoColor=white" alt="Architecture" height="30"/>
</p>

<br>

</div>

---

This repository contains the implementation and experimental framework for a fault-tolerant secure boot system that uses progressive attestation to achieve resilience under adverse conditions.

## System Overview

PAC implements a three-tier boot architecture where each tier provides incrementally stronger security guarantees. Tier 1 establishes minimal functionality with an atomic boot journal for state persistence. Tier 2 adds network connectivity and attempts remote attestation. Tier 3 represents full operational mode with cryptographic attestation and runtime monitoring. The system degrades gracefully when faults occur, maintaining availability while reducing functionality.

The boot journal uses double-buffered writes with CRC32 verification to survive power failures and storage corruption. Health checks evaluate system state across multiple dimensions including memory, storage, temperature, and ECC errors. A policy engine determines tier transitions based on health scores and attestation results. Runtime monitoring enables dynamic promotion and degradation as conditions change.

## Prerequisites

Ubuntu 22.04 LTS with the following packages:
- QEMU (arm64 system emulation)
- swtpm and tpm2-tools
- Cross-compilation toolchain for aarch64
- Standard build tools (gcc, make, git)
- Python 3 with Flask and cryptography modules

The setup script handles package installation automatically.

## Quick Start

Clone the repository and initialize the environment:

```bash
git clone https://github.com/anonymous-shadowhawk/paper_artifacts.git
cd paper_artifacts
./setup_pac_lab.sh
```

Build the complete system including kernel, bootloader, and initramfs:

```bash
./build_pac_system.sh
```

This compiles U-Boot, builds a custom Linux kernel, cross-compiles BusyBox and OpenSSL for ARM64, and constructs the initramfs containing all PAC components. Expect approximately 30-40 minutes for a full build on modern hardware.

Launch the system in QEMU with TPM emulation:

```bash
./real_pac_boot.sh
```

The system boots through Tier 1, performs health assessment, establishes network connectivity for Tier 2, and attempts attestation for Tier 3 promotion. Watch the console output to observe tier transitions and policy decisions.

## Expected Behavior

A successful boot proceeds as follows. Tier 1 initializes the boot journal, mounts essential filesystems, and runs health checks. With sufficient health score (threshold 3/10), the system promotes to Tier 2 by configuring network interfaces and mounting the Tier 2 rootfs. If health remains excellent (threshold 6/10) and network connectivity exists, Tier 3 promotion begins.

Tier 3 requires successful attestation with a remote verifier. Start the verifier in a separate terminal before booting:

```bash
cd verifier
python3 verifier.py
```

The attestation agent generates an RSA-2048 key pair, collects platform measurements including boot state and PCR values, constructs an EAT token, and submits it to the verifier at 10.0.2.2:8080. Upon verification success, the system achieves Tier 3 and starts the policy monitor daemon.

The policy monitor runs continuously, checking verifier availability and system health every 30 seconds. It triggers degradation when the verifier becomes unreachable or health deteriorates. Recovery happens automatically when conditions improve.

## Fault Injection Experiments

The fault injection framework tests system resilience across multiple fault classes. Boot-time faults corrupt the journal, inject bit flips, simulate power cuts, and manipulate attestation signatures. Runtime faults kill the verifier process, inject ECC errors, trigger watchdog timeouts, and simulate storage failures.

Run a single fault type:

```bash
cd faultlab
python3 pac_fault_injector.py --fault bit_flip --trials 100
```

Execute full experimental campaigns:

```bash
python3 pac_fault_injector.py --mode boot --trials 100
python3 pac_fault_injector.py --mode runtime --trials 100
python3 pac_fault_injector.py --mode recovery --trials 50
```

## Repository Structure

Core components live in dedicated directories. The `journal/` directory contains the atomic boot journal implementation with double-buffered writes. Health check code resides in `health_check/` and evaluates multiple system dimensions. Policy logic for tier transitions exists in `policy/`. The remote verifier implementation with EAT token processing occupies `verifier/`.

Tier-specific content separates cleanly. `tier1_initramfs/` holds the initial ramdisk with progressive boot logic and all PAC helper scripts. `tier2/` and `tier3/` contain their respective rootfs images and initialization scripts. Boot configuration including U-Boot device trees and kernel image metadata sits in `boot/`.

The fault injection framework lives entirely in `faultlab/`. This includes the main injector (`pac_fault_injector.py`), result analyzer (`analyze_results.py`), and non-interactive boot script for automated testing.

## Build Details

The build system handles significant complexity. It clones and builds U-Boot from source with QEMU ARM64 configuration. Linux kernel 6.1+ gets configured with TPM support, dm-verity, and necessary crypto modules. BusyBox provides a minimal userspace compiled statically for ARM64. OpenSSL must be cross-compiled dynamically since the attestation agent needs shared library access.

The initramfs construction merges BusyBox, cross-compiled binaries, PAC helper scripts, shared libraries for OpenSSL, and the pre-built journal tool. The build script copies source files from `tier1_initramfs/build/` to `tier1_initramfs/rootfs/`, creates the CPIO archive, and compresses it with gzip. Final size targets 28MB for the complete initramfs.

Tier 2 and Tier 3 rootfs images use ext4 filesystems with dm-verity hashes for integrity verification. Manifest files contain SHA256 checksums and RSA signatures for each tier's rootfs.

## Troubleshooting

Boot failures typically stem from missing binaries or incorrect architecture. Verify that `journal_tool_arm64` exists in `journal/` and gets copied to `tier1_initramfs/build/bin/journal_tool`. Check that OpenSSL shared libraries populate `tier1_initramfs/rootfs/lib/`. Run `file` on binaries to confirm they target ARM64.

Attestation failures often indicate OpenSSL issues. The cryptographic agent requires `/dev/urandom` for entropy and proper library linkage. If attestation consistently fails, check that dynamic libraries load correctly inside QEMU. The fallback mock attestation path will activate if cryptographic attestation proves impossible.

Network problems prevent Tier 2 promotion. QEMU's user-mode networking maps the host's 127.0.0.1:8080 to the guest's 10.0.2.2:8080. Ensure the verifier runs on the host before attempting Tier 3 attestation. Test connectivity from inside QEMU with `ping 10.0.2.2`.

## Cleaning and Rebuilding

Remove build artifacts while preserving source code:

```bash
./cleanup_build_artifacts.sh
```

This deletes kernel builds, U-Boot objects, generated images, and temporary files but keeps journal sources, PAC scripts, and rootfs templates. Rebuild proceeds from scratch using existing source files.

## System Requirements

Host system needs at least 4GB RAM for comfortable builds and 8GB disk space for artifacts. QEMU guest receives 2GB RAM by default. A multi-core processor significantly reduces build time since kernel compilation parallelizes well.

The ARM64 cross-toolchain must match the target architecture exactly. Ubuntu's `gcc-aarch64-linux-gnu` package provides the necessary compiler, linker, and runtime libraries. Debian-based distributions work similarly. Other distributions may need alternative package names.

## Replication Notes

Experimental results depend on consistent timing and fault injection precision. QEMU's emulation speed varies with host performance. Run experiments on dedicated hardware without competing workloads for reproducible timing measurements. The non-interactive boot script in `faultlab/` standardizes the testing environment.

Fault injection timing matters for boot-time faults. Journal corruption must occur before the init process reads the journal file. Power cuts need precise timing to catch the system during writes. Runtime faults require the system to reach stable state before injection begins. Review `pac_fault_injector.py` for specific timing parameters used in published experiments.

The policy monitor's 30-second polling interval affects recovery measurements. Faster polling detects failures sooner but increases overhead. The current setting balances detection latency with system load. Modify `policy_monitor.sh` if different trade-offs suit your evaluation.
