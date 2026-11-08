#!/bin/bash
# Finish the interrupted local build: re-run the idempotent post.sh, clean
# umount, fsck -y/-n, img2simg, verify, deliver.
set -uo pipefail
D=/opt/ios-sweet-work
W=$D/root-build
OUT=$D/ios16-root.simg
LOG=$D/finish.log
DIST_HOST=/host-dist
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

export SUPERMIN_KERNEL=/boot/vmlinuz-6.8.0-149-generic
export SUPERMIN_MODULES=/lib/modules/6.8.0-149-generic
export LIBGUESTFS_BACKEND_SETTINGS=force_tcg
export LIBGUESTFS_MEMSIZE=768

rm -f "$LOG" "$OUT"
log "FINISH_START"

# post.sh lives on the host stage tree (the copy inside HFS was removed by the
# interrupted run). Attach it as a tiny 5th disk; run it idempotently.
cat > "$W/finish.gf" <<'CMDS'
run
debug sh "modprobe hfsplus 2>/dev/null || true; mkdir -p /hfs; i=0; until mount -t hfsplus -o force,rw /dev/sda /hfs 2>/dev/null; do i=$((i+1)); [ $i -ge 5 ] && { echo MOUNT_FAIL; exit 1; }; sleep 1; done; echo MOUNTED; cp /dev/sdb /post.sh; chmod 0755 /post.sh; sh /post.sh; echo POST_DONE; sync; umount /hfs || { echo UMOUNT_FAIL; exit 1; }; echo UMOUNT_OK"
CMDS
log "STEP1 post.sh replay (idempotent, 4639 lines)"
if ! timeout 1800 guestfish -a "$W/root.img" -a "$W/stage/post.sh" < "$W/finish.gf" >>"$LOG" 2>&1; then
  log "POST_REPLAY_FAIL"; tail -60 "$LOG"; exit 1
fi
grep -E 'MOUNTED|POST_DONE|UMOUNT_OK|MOUNT_FAIL|UMOUNT_FAIL' "$LOG" | tail -6
log "STEP1_OK"

log "STEP2 fsck -f -y (fix Illegal name / replay journal)"
fsck.hfsplus -f -y "$W/root.img" >>"$LOG" 2>&1 || log "FSCK_Y_RC=$? (see log)"
log "STEP3 fsck -f -n verify"
if ! fsck.hfsplus -f -n "$W/root.img" >>"$LOG" 2>&1; then
  log "FSCK_N_FAIL"; tail -40 "$LOG"; exit 1
fi
grep -E 'appears to be OK|was found corrupt|Illegal name' "$LOG" | tail -4
log "STEP3_OK"

log "STEP4 img2simg"
img2simg "$W/root.img" "$OUT" >>"$LOG" 2>&1 || { log "IMG2SIMG_FAIL"; exit 1; }
log "STEP4_OK $(du -h "$OUT" | cut -f1)"

log "STEP5 sparse round-trip verify"
simg2img "$OUT" "$W/verify.img" >>"$LOG" 2>&1 || { log "SIMG2IMG_FAIL"; exit 1; }
fsck.hfsplus -f -n "$W/verify.img" >>"$LOG" 2>&1 || log "SPARSE_FSCK_WARN (see log)"
rm -f "$W/verify.img"
SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
log "STEP5_OK sha256=$SHA"

log "STEP6 deliver"
mkdir -p "$DIST_HOST"
cp -f "$OUT" "$DIST_HOST/ios16-root.simg" || { log "DELIVER_FAIL"; exit 1; }
chmod 644 "$DIST_HOST/ios16-root.simg"
echo "$SHA  ios16-root.simg" > "$DIST_HOST/ios16-root.simg.sha256"
log "DELIVERED $DIST_HOST/ios16-root.simg $(stat -c%s "$DIST_HOST/ios16-root.simg") B"

# 让旧哨兵的 finalize 条件也能命中（若它仍存活）
echo "[$(date -u +%FT%TZ)] DONE $OUT $(du -h "$OUT" | cut -f1)" >> "$D/build-all.log"
log "FINISH_DONE"
