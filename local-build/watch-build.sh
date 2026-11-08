#!/bin/bash
# Sentinel: watch the local ios16-root.simg build, finalize deliverables on success.
D=/data/data/com.dsharnessmobile.shell/files/home/.dsh/ubuntu-rootfs/opt/ios-sweet-work
REPO=/data/data/com.dsharnessmobile.shell/files/home/.dsh/workspaces/incoming/rom-build
LOG=$D/build-all.log
DIST=$REPO/dist
mark() { echo "[$(date -u +%FT%TZ)] $*"; }
snap() {
  local last files disk
  last=$(tail -1 "$LOG" 2>/dev/null)
  files=$(ls -lh "$D"/root-build/*.dmg "$D"/root-build/*.dmg.part "$D"/root-build/*.tar "$D"/root-build/root.img "$D"/ios16-root.simg 2>/dev/null | awk '{printf "%s=%s ", $9, $5}' | sed "s|$D/||g")
  disk=$(df -h /data | tail -1 | awk '{print $4}')
  mark "beat | $last | $files| free=$disk"
}
finalize() {
  mark "FINALIZE: copying deliverables"
  mkdir -p "$DIST"
  cp -f "$D/ios16-root.simg" "$DIST/ios16-root.simg" || { mark "COPY_FAIL"; return 1; }
  chmod 644 "$DIST/ios16-root.simg"
  sha256sum "$DIST/ios16-root.simg" | tee "$DIST/ios16-root.simg.sha256"
  python3 "$REPO/repo/tools/verify-waffle-boot.py" "$DIST/shim-boot-waffle.img" > "$DIST/boot-verify.txt" 2>&1
  cat > "$DIST/BUILD-REPORT.md" <<EOF
# 一加12 / PJD110 — iOS 16 (XNU) 本地构建报告

构建时间: $(date -u +%FT%TZ)
构建宿主: 本设备 Android chroot -> Ubuntu 24.04 arm64 (TCG, 无 /dev/kvm)
源码: https://github.com/NJS98-UI/Android-ios @ $(cd "$REPO/repo" && git rev-parse --short HEAD)

## 产物
| 文件 | 大小 | SHA256 |
|---|---|---|
| shim-boot-waffle.img | $(stat -c%s "$DIST/shim-boot-waffle.img") B | $(sha256sum "$DIST/shim-boot-waffle.img" | cut -d' ' -f1) |
| ios16-root.simg | $(stat -c%s "$DIST/ios16-root.simg") B | $(sha256sum "$DIST/ios16-root.simg" | cut -d' ' -f1) |

## 关键日志
\`\`\`
$(grep -E '^\[.*(=====|DONE|FAIL|WARN|apfs_extract ready|downloaded )' "$LOG" | tail -40)
\`\`\`

## 刷机（会清空 Android userdata，且不可逆）
\`\`\`
cd dist
bash flash-waffle.sh    # 需要解锁 BL、fastboot、输入 ERASE
\`\`\`
或手工：
\`\`\`
fastboot -S 512M flash userdata ios16-root.simg
fastboot boot shim-boot-waffle.img
\`\`\`
注意：这是实验性 bring-up，从未在真机启动验证过；首次启动可能黑屏或停在 Apple logo。
EOF
  mark "DONE_ALL dist=$DIST size=$(du -h "$DIST/ios16-root.simg" | cut -f1)"
}
mark "WATCHER_START pid=$$"
snap
# guestfish 只在整条 debug sh 结束时才把输出写回日志，注入 11G 数据期间
# build-all.log 静默 30+ 分钟是常态。活性判据改为：root.img 的 mtime/大小、
# qemu 进程、或 sparse 产物三者之一在动即视为活着；连续 45 分钟全静默才判死。
ROOTIMG=$D/root-build/root.img
OUT=$D/ios16-root.simg
last_activity=$(date +%s); idle=0
for i in $(seq 1 720); do
  if grep -q '] DONE /opt/ios-sweet-work/ios16-root.simg' "$LOG" 2>/dev/null; then snap; finalize; exit 0; fi
  if grep -qE '\] (ROOT_BUILD_FAIL|DOWNLOAD_FAIL|APFS_EXTRACT_FAIL|SIMG2IMG_FAIL)' "$LOG" 2>/dev/null; then
    mark "BUILD_FAILED"; tail -60 "$LOG"; exit 1
  fi
  now=$(date +%s); active=0
  [ -f "$ROOTIMG" ] && [ $((now - $(stat -c %Y "$ROOTIMG" 2>/dev/null || echo 0))) -lt 180 ] && active=1
  [ -f "$OUT" ] && [ $((now - $(stat -c %Y "$OUT" 2>/dev/null || echo 0))) -lt 180 ] && active=1
  [ $((now - $(stat -c %Y "$LOG" 2>/dev/null || echo 0))) -lt 300 ] && active=1
  if [ "$active" = 1 ]; then last_activity=$now; idle=0; else idle=$((now - last_activity)); fi
  [ "$idle" -ge 2700 ] && { mark "BUILD_IDLE_45MIN"; tail -60 "$LOG"; exit 1; }
  [ $((i % 10)) -eq 1 ] && mark "alive idle=${idle}s"
  snap
  sleep 30
done
mark "WATCHER_TIMEOUT_6H"
exit 2
