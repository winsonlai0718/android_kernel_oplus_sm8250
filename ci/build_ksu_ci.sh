#!/bin/bash

KERNEL_ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KERNEL_OUTPUT=$KERNEL_ROOT/out/arch/arm64/boot
KSU_KBUILD="$KERNEL_ROOT/KernelSU/kernel/Kbuild"
KCONFIG_FILE="$KERNEL_ROOT/drivers/Kconfig"
KSU_KCONFIG_LINE='source "drivers/kernelsu/Kconfig"'
MAKEFILE_FILE="$KERNEL_ROOT/drivers/Makefile"
KSU_MAKEFILE_LINE='obj-$(CONFIG_KSU) += kernelsu/'

# ARCH
export ARCH=arm64
export SUBARCH=arm64

# AnyKernel
AK3_PATH=$KERNEL_ROOT/anykernel
CUSTOM_AK3_NAME=BT-ReSukiSU-BPF-5.10
FULL_AK3_NAME=$CUSTOM_AK3_NAME-$(date +%Y-%m-%d)

if [ ! -d "$AK3_PATH" ]; then
    git clone --depth=1 -b realme-sm8250 https://github.com/xxtvrxx233/AnyKernel3.git $AK3_PATH
fi

# Clean existing anykernel packages
if find $AK3_PATH -maxdepth 1 -type f -name "*.zip" | grep -q .; then
    find $AK3_PATH -maxdepth 1 -type f -name "*.zip" -delete
fi

# ReSukiSU
# WB: pin KSU to the exact commit baked into the running kernel
# (v4.2.0-rc1-3c188288), instead of pulling today's main branch.
curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/3c188288/kernel/setup.sh" | bash -s -- 3c188288

# Modify repo name
BASE_VER=$(grep -oE 'expr [0-9]+' "$KERNEL_ROOT/KernelSU/kernel/Kbuild" | awk '{print $2}' || echo "30000")

cd "$KERNEL_ROOT/KernelSU"
KSU_LOCAL_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo "0")
KSU_HASH=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
KSU_VERSION_CODE=$(expr $BASE_VER + $KSU_LOCAL_VERSION + 700 2>/dev/null || echo "30700")
KSU_TAG=$(git describe --abbrev=0 --tags 2>/dev/null || echo "v4.1.0")
cd "$KERNEL_ROOT"

FINAL_KSU_VER="${KSU_TAG}-${KSU_HASH}@xxtvrxx233-Github_actions"
echo ">>> Version Code: $KSU_VERSION_CODE"
echo ">>> Version Name: $FINAL_KSU_VER"

export KSU_MAKE_ARGS="REPO_NAME=xxtvrxx233-Github_actions KSU_VERSION_FULL=$FINAL_KSU_VER KSU_COMMIT_SHA=$KSU_HASH KSU_VERSION=$KSU_VERSION_CODE"

# ---- WorkBuddy touch-response source patches (applied before make) ----
python3 - "$KERNEL_ROOT" <<'WBPATCH'
import sys, os
root = sys.argv[1]

def repl(path, old, new, label, required=True):
    p = os.path.join(root, path)
    if not os.path.isfile(p):
        if required: raise SystemExit("WBPATCH MISSING FILE: " + path)
        print("WBPATCH SKIP (no file): " + label); return
    s = open(p, encoding="utf-8").read()
    if old not in s:
        if required: raise SystemExit("WBPATCH ANCHOR NOT FOUND: " + label)
        print("WBPATCH SKIP (no anchor): " + label); return
    open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
    print("WBPATCH OK: " + label)

# (0) input_boost_timeout() is defined later in kernel/sysctl.c; the fix
#     below references it, so add a forward declaration first.
repl("kernel/sysctl.c",
"static ktime_t ib_last_time;\n\nvoid enable_input_boost_timer(void)",
"static ktime_t ib_last_time;\n\n/* WB: forward declaration (definition appears later) */\nenum hrtimer_restart input_boost_timeout(struct hrtimer *timer);\n\nvoid enable_input_boost_timer(void)",
"forward-declare-timeout")

# (1) ROOT CAUSE OF THE REBOOT: input_boost_ctrl_handler() starts an
#     hrtimer that was never initialised (function == NULL, duration == 0).
#     Writing /proc/sys/kernel/input_boost_enabled=1 crashed the kernel.
repl("kernel/sysctl.c",
'''	ib_last_time = ktime_get();
	ktime = ktime_set(0, intput_boost_duration);

	hrtimer_start(&ibtimer, ktime, HRTIMER_MODE_REL);''',
'''	ib_last_time = ktime_get();
	/* WB: lazily initialise the hrtimer. Stock code starts an
	 * uninitialised timer here and reboots the device. */
	if (!intput_boost_duration)
		intput_boost_duration = INPUT_BOOST_DURATION;
	if (!ibtimer.function) {
		hrtimer_init(&ibtimer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
		ibtimer.function = &input_boost_timeout;
	}
	ktime = ktime_set(0, intput_boost_duration);

	hrtimer_start(&ibtimer, ktime, HRTIMER_MODE_REL);''',
"fix-input-boost-hrtimer")

# (2) WALT: runtime writes are rejected (handler returns -EPERM),
#     so shorten the compile-time load-tracking window to 1 tick.
repl("kernel/sched/walt.c",
"unsigned int sysctl_sched_ravg_window_nr_ticks = (HZ / NR_WINDOWS_PER_SEC);",
"unsigned int sysctl_sched_ravg_window_nr_ticks = 1; /* WB: faster load detection */",
"walt-window-1tick")

# (3) sched_assist_scene stays 0 on this port (no ORMS scene published),
#     so SA_SLIDE / SA_INPUT boost values are dead code. Add a 120Hz fallback.
repl("include/linux/sched_assist/sched_assist_slide.c",
'''	} else if (sched_assist_scene(SA_INPUT)) {
		if (sysctl_frame_rate <= 90)
			*maxtime = 8;
		else if (sysctl_frame_rate <= 120)
			*maxtime = 7;
		else
			*maxtime = 6;
	}
}''',
'''	} else if (sched_assist_scene(SA_INPUT)) {
		if (sysctl_frame_rate <= 90)
			*maxtime = 8;
		else if (sysctl_frame_rate <= 120)
			*maxtime = 7;
		else
			*maxtime = 6;
	} else {
		/* WB: no ORMS scene on this port; keep the 120Hz input value */
		*maxtime = 7;
	}
}''',
"sched-assist-input-fallback", required=False)

# (4) Match the real 120Hz panel and enable slide boost by default.
#     slide_boost_enabled=1 was verified safe at runtime on the device.
repl("kernel/sysctl.c", "int sysctl_frame_rate = 60;",
     "int sysctl_frame_rate = 120; /* WB: panel is 120Hz */",
     "frame-rate-120", required=False)
repl("include/linux/sched_assist/sched_assist_slide.c",
     "int sysctl_slide_boost_enabled = 0;",
     "int sysctl_slide_boost_enabled = 1; /* WB: verified safe */",
     "slide-boost-default", required=False)
WBPATCH

# ---- drivers/Kconfig ----
echo "Injecting KSU Kconfig entry..."
echo "" >> "$KCONFIG_FILE"
echo "$KSU_KCONFIG_LINE" >> "$KCONFIG_FILE"

# ---- drivers/Makefile ----
echo "Injecting KSU Makefile entry..."
echo "" >> "$MAKEFILE_FILE"
echo "$KSU_MAKEFILE_LINE" >> "$MAKEFILE_FILE"

# Clang Toolchain Logic
if [ ! -d "$KERNEL_ROOT/zyc-clang-16/bin" ]; then
    echo "Clang not found or cache missed, downloading..."
    if [ ! -f "/tmp/Clang-16.0.6-20250721.tar.gz" ]; then
        wget -O /tmp/Clang-16.0.6-20250721.tar.gz https://github.com/ZyCromerZ/Clang/releases/download/16.0.6-20250721-release/Clang-16.0.6-20250721.tar.gz
    fi
    mkdir -p "$KERNEL_ROOT/zyc-clang-16"
    tar -xvf /tmp/Clang-16.0.6-20250721.tar.gz -C "$KERNEL_ROOT/zyc-clang-16"
else
    echo "Clang toolchain restored from cache!"
fi

export CLANG_PATH=$KERNEL_ROOT/zyc-clang-16/bin
export PATH="/usr/lib/ccache:$CLANG_PATH:$PATH"
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

KERNEL_DEFCONFIG="vendor/kona-perf_defconfig vendor/ksu.config"

echo
echo "Kernel is going to be built using $KERNEL_DEFCONFIG"
echo


echo "=== KERNEL CONFIGURATION LOG ===" > "$KERNEL_ROOT/build.log"
make CC="ccache clang" AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip LLVM=1 LLVM_IAS=1 O=out $KERNEL_DEFCONFIG $KSU_MAKE_ARGS 2>&1 | tee -a "$KERNEL_ROOT/build.log"

echo "=== KERNEL COMPILATION LOG ===" >> "$KERNEL_ROOT/build.log"
make CC="ccache clang" AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip LLVM=1 LLVM_IAS=1 O=out $KSU_MAKE_ARGS -j$(nproc --all) 2>&1 | tee -a "$KERNEL_ROOT/build.log"

echo "Build complete"

ccache -s

if [ -f "$KERNEL_OUTPUT/dtb" ] && [ -f "$KERNEL_OUTPUT/dtbo.img" ] && [ -f "$KERNEL_OUTPUT/Image" ]; then
    cd $AK3_PATH
    cp "$KERNEL_OUTPUT/dtb"   .
    cp "$KERNEL_OUTPUT/dtbo.img"  .
    cp "$KERNEL_OUTPUT/Image"     .

echo "[+] Kernel files copied to $AK3_PATH"
else
    echo "[-] Error: Kernel files missing!"
    exit 1
fi
