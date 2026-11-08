# 一加12 / PJD110 — iOS 16 (XNU) 本地构建报告

- 构建时间：2026-11-08 13:58Z → 16:24Z（本机，无云端 CI）
- 构建宿主：本设备 Android 14 内核 + Ubuntu 24.04 arm64 root-chroot；无 `/dev/kvm`，libguestfs 走 `force_tcg` 软模拟
- 源码：`https://github.com/NJS98-UI/Android-ios` @ `36e98ac`（私有仓库）
- Apple 输入：iPhone10,3 16.7.16 (20H392) IPSW，HTTP Range 只取 3 个 dmg，CRC-32 全过

## 产物（dist/）

| 文件 | 大小 | SHA256 |
|---|---|---|
| `shim-boot-waffle.img` | 16,785,408 B | `374cb7f26be0079c9091da2c31c8d851f6fd3c3b879cdb9dc221972c5d513ea4` |
| `ios16-root.simg` | 12,140,814,096 B（展开 16 GiB） | `6b77a7d8952f3c5804169afb36420a8c4815e490367fde8b79e2b5ad0749ae0b` |

- boot.img v4：payload v2，XNU `kernel.sweet` + 12,632 B waffle ADT（含 D22AP `/product`），fb 0/5760/1440×3168/32，root cmdline `rd=ufsroot0 ...`。从源码重建的 payload 与仓库提交的 ramdisk **逐字节一致**。
- sparse 头：`0xed26ff3a` v1.0，4096 B/block，4,194,304 blocks = 17,179,869,184 B raw，27,772 chunks。
- HFS+ 卷：`fsck.hfsplus -f -y` 修复 Linux/Apple 非 ASCII 名分解差异 → `-f -n` 报 `appears to be OK`；`simg2img` 回读再 fsck 同样干净。
- root 内容体检：`launchd.plist`、44 个 dyld 硬链接、cryptex OS/App、systembag.kb、Setup/激活/watchdog tweaks、VirtualAudio 禁用全部到位。

## 本地构建中修掉的真 bug

`tools/build-ios-root.sh` 的 `inject.gf` 里 `i=\$((i+1))` / `\$i` 在 guestfish 的字符串解析器里是**非法转义**，一进 3/4 阶段就 `invalid escape sequence`。CI 上次被人手动取消在下载阶段，没暴露这个。修法：heredoc 是单引号，`$` 本就是字面量，去掉反斜杠；另加 `LIBGUESTFS_BACKEND_SETTINGS=force_tcg`，让无 KVM 的 Android chroot / 容器也能启动 appliance。5 盘注入、post.sh、干净 umount、fsck、img2simg 全链已在本机端到端验证。

## 一键刷机（会清空 Android userdata，不可逆）

```sh
cd dist
bash flash-waffle.sh     # 需解锁 BL + fastboot + 输入 ERASE
```

等价手工：

```sh
fastboot -S 512M flash userdata ios16-root.simg
fastboot boot shim-boot-waffle.img
```

## 风险（照抄上游，别装看不见）

- 这是**实验性 bring-up，从未在真机启动验证过**：splash FB 物理地址、真实 panel rowBytes、touch IC/IRQ、gpio-keys 都还要 live FDT；首启可能黑屏、卡 Apple logo 或只出控制台。
- `flash userdata` 会**抹掉 Android 全部用户数据**；bootloader / recovery / modem / persist 不碰。动手前先备份 `persist`、`modemst1/2`、`fsg`、`fsc`、`boot`、`dtbo`、`vbmeta`。
- Qualcomm ABL 大镜像刷完常卡在 "Sending"，用 Power+VolumeDown 重进 fastboot，别拔线。

## 复现

- `build-all.sh`：容器内全量驱动（编 apfs_extract → 下 IPSW → 四阶段组装）
- `finish-root.sh`：注入被系统回收后续做（幂等重放 post.sh → fsck → img2simg → 校验）
- 关键环境变量：`SUPERMIN_KERNEL=/boot/vmlinuz-6.8.0-149-generic`、`SUPERMIN_MODULES=/lib/modules/6.8.0-149-generic`、`LIBGUESTFS_BACKEND_SETTINGS=force_tcg`
