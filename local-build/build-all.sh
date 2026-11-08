#!/bin/bash
# OnePlus 12 (waffle/PJD110) iOS 16 root build driver.
# Runs inside the Seagull Ubuntu container (root chroot, no /dev/kvm).
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

REPO=/opt/ios-sweet
WORK=/opt/ios-sweet-work/root-build
LOG=/opt/ios-sweet-work/build-all.log
OUT=/opt/ios-sweet-work/ios16-root.simg
IPSW='https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw'

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }
stage() { log "===== STAGE: $* ====="; }

mkdir -p "$WORK"
log "START pid=$$ host=$(uname -m) free=$(df -h /opt | tail -1 | awk '{print $4}')"

stage "deps (git for apfs-fuse clone)"
if ! command -v git >/dev/null; then
  apt-get update -qq >>"$LOG" 2>&1 && \
  apt-get install -y --no-install-recommends git ca-certificates >>"$LOG" 2>&1 || {
    log "APT_FAIL"; exit 1; }
fi
log "git: $(git --version)"

stage "build apfs_extract (offline APFS -> pax tar)"
if [ ! -x "$WORK/build/apfs_extract" ]; then
  WORK="$WORK" bash "$REPO/tools/build-apfs-extract.sh" \
    "$WORK/build" "$WORK/apfs-fuse" >>"$LOG" 2>&1 || {
      log "APFS_EXTRACT_FAIL"; tail -50 "$LOG"; exit 1; }
fi
log "apfs_extract ready: $(ls -l "$WORK/build/apfs_extract" | awk '{print $5}') bytes"

stage "download 3 IPSW dmgs (HTTP Range, resumable, CRC-32)"
for m in 087-86698-044.dmg 087-86593-047.dmg 087-86715-047.dmg; do
  python3 "$REPO/tools/remotezip.py" "$IPSW" "$m" "$WORK" >>"$LOG" 2>&1 || {
    log "DOWNLOAD_FAIL $m"; exit 1; }
  log "downloaded $m ($(du -h "$WORK/$m" | cut -f1))"
done
mv -f "$WORK/087-86698-044.dmg" "$WORK/OS.dmg"
mv -f "$WORK/087-86593-047.dmg" "$WORK/SystemOS.dmg"
mv -f "$WORK/087-86715-047.dmg" "$WORK/AppOS.dmg"

stage "build-ios-root.sh (APFS tars -> HFS+ -> sparse)"
# Android shares its 6.1 kernel with the container; the container's own 6.8
# kernel + modules are what the supermin appliance must boot. No /dev/kvm =>
# force TCG. force_tcg is harmless on a KVM host.
export SUPERMIN_KERNEL=/boot/vmlinuz-6.8.0-149-generic
export SUPERMIN_MODULES=/lib/modules/6.8.0-149-generic
export LIBGUESTFS_BACKEND_SETTINGS=force_tcg
export LIBGUESTFS_MEMSIZE=1024
rm -f "$OUT"
WORK="$WORK" bash "$REPO/tools/build-ios-root.sh" \
  "$WORK/OS.dmg" "$WORK/SystemOS.dmg" "$WORK/AppOS.dmg" "$OUT" 16G \
  >>"$LOG" 2>&1 || { log "ROOT_BUILD_FAIL"; tail -80 "$LOG"; exit 1; }

stage "final verify"
sha256sum "$OUT" | tee -a "$LOG"
simg2img "$OUT" "$WORK/verify.img" >>"$LOG" 2>&1 || { log "SIMG2IMG_FAIL"; exit 1; }
fsck.hfsplus -f -n "$WORK/verify.img" >>"$LOG" 2>&1 || log "FSCK_WARN (see log)"
rm -f "$WORK/verify.img"
log "DONE $OUT $(du -h "$OUT" | cut -f1)"
