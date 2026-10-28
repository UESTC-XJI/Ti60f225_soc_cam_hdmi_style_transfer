#include "camera_3a.h"
/* Highlights soften the metering goal rather than unconditionally darkening
 * an already dark scene. The bounded continuous goal avoids two competing
 * increase/decrease loops around a hard saturation threshold.
 *
 * 2026-10-27: knee 10‰ -> 100‰, cap 24 -> 16 (floor 112).
 * 依据：AE 的 hot 阈值 232 是对【增益后】码值判的，而当前色彩校准
 * R/B 增益 520 是 Q8.8 (x2.03)，且 rgb_gain_v1 在数据链第一级就把码值
 * 饱和到 255 —— 原始码值 ~114 就等于 232、~126 就裁顶。所以 hot 实际
 * 数的是"被色彩校准裁顶的像素"，knee 取 10‰ 会让多数室内场景直接
 * 把 goal 钉在下限 104（-0.30 EV），画面整体压暗、暗部丢层次。
 * 抬到 100‰ 只对真正高光主导的帧生效，cap 收到 16（floor 112）进一步
 * 限制压暗幅度。若将来重做色彩校准把增益降回 <=256，这两个数可以再调。 */
uint32_t camera_ae_goal(uint32_t high) {
  uint32_t reduction=high>100?(high-100)/4u:0;
  return 128u-(reduction>16u?16u:reduction);
}
/* Half-line units. Large errors use a ratio correction (1/2..2x), while
 * medium/fine errors use half/quarter correction after settled statistics. */
uint32_t camera_ae_target(uint32_t current,uint32_t maximum,uint32_t mean,uint32_t high) {
  uint32_t target=current,goal=camera_ae_goal(high);
  uint32_t error=mean>goal?mean-goal:goal-mean;
  if(error>4) {
    uint64_t scaled=(uint64_t)current*goal/(mean?mean:1u);
    if(error<24) {
      uint32_t divisor=error<12?4u:2u;
      if(scaled>current)scaled=current+(scaled-current)/divisor;
      else scaled=current-(current-scaled)/divisor;
    }
    uint32_t lo=current/2u;
    uint64_t hi=(uint64_t)current*2u;
    target=(uint32_t)(scaled<lo?lo:(scaled>hi?hi:scaled));
  }
  if(target<4)target=4;
  if(target>maximum)target=maximum;
  return target;
}

/*==========================================================================
 * AGC —— 模拟增益自动控制（2026-10-28）
 *
 * 为什么需要：曝光已顶到 `2*VTS-11`（当前 VTS=1457 ⇒ 上限 2903 半行），
 *   rolling shutter 下积分时间 ≈ 帧周期 ⇒ **曝光顶满后画面再暗就没救了**。
 *   实测：白天 mean 116 有余量；傍晚场景变暗后曝光顶死、mean 只剩 75（goal 128）。
 *   固定增益两头不讨好：亮场景 6.16x 刚好，暗场景不够；调到 9x 则亮场景裁顶。
 *
 * 策略依据 SC431HAI 手册 §2.4.1（原文）：
 *   「曝光时间优先，曝光时间已经最长无法继续调整时，调整增益」
 *   「增益开启，将直接导致平均噪声呈倍数放大；而曝光时间加大，则有助于提升信噪比」
 *   ⇒ **只在曝光饱和且仍然偏暗时才加增益**，一旦有余量就优先退回增益。
 *
 * 档位取自手册表 2-7（每档 ×1.25 ≈ 1/3 stop）：
 *   0: 0x83/0x20 =  6.160x   1: 0x83/0x28 =  7.700x   2: 0x83/0x32 =  9.625x
 *   3: 0x83/0x3e = 11.935x   4: 0x87/0x27 = 15.015x   5: 0x87/0x31 = 18.865x
 *   6: 0x87/0x3d = 23.485x
 * 起点 6.160x 与 camera_init_table.h 里的出厂值一致。
 *
 * ⚠ 手册 §2.4.2：增益第 N 帧写入、**第 N+2 帧生效** ⇒ 改动后要等几帧再判，
 *   否则会连着加好几档（调用方用 agc_settle 计数保证）。
 * ⚠ 初值 6.16x 是出厂值；第一次 AGC 动作前保持不动。
 *========================================================================*/
static const unsigned char AGC_ANA[7]  = {0x83,0x83,0x83,0x83,0x87,0x87,0x87};
static const unsigned char AGC_FINE[7] = {0x20,0x28,0x32,0x3e,0x27,0x31,0x3d};
#define AGC_STEPS 7

unsigned camera_agc_steps(void) { return AGC_STEPS; }

/* 取第 index 档的 (0x3e08, 0x3e09) 码。越界钳到端点。 */
void camera_agc_code(unsigned index, unsigned char *ana, unsigned char *fine) {
  if (index >= AGC_STEPS) index = AGC_STEPS - 1;
  *ana = AGC_ANA[index];
  *fine = AGC_FINE[index];
}

/* 决策：返回 +1 加一档 / -1 退一档 / 0 不动。
 *   up  : 曝光已饱和（差 <= 2 半行）且 mean 明显低于 goal  —— 才允许加（手册策略）
 *   down: mean 明显高于 goal 且还有增益可退 —— 优先退增益（比压曝光干净）
 * 阈值留了死区，避免在边界来回抖。 */
int camera_agc_step(unsigned exposure, unsigned maximum, unsigned mean,
                    unsigned goal, unsigned index, unsigned hot) {
  int saturated = (exposure + 2u >= maximum);
  /* 2026-10-28 方案 A：**高光护栏**。
   *   实测：无护栏时 AGC 从 6.16x 一路加到 11.935x，mean 从 75 到 114（达标），
   *   但 hot 从 0 飙到 282（28% 像素裁顶），原画那半高光炸白。
   *   手册明确"增益开启会让平均噪声成倍放大"，且增益会**提前一档裁顶** ⇒
   *   一旦高光已经超过 15%，继续加增益只会让亮部更糟，不再往上走。
   *   （15% 是个保守值：hot 的统计口径是"接近饱和的像素占比"。） */
  int headroom_ok = (hot <= 150u);
  if (saturated && headroom_ok && mean + 6u < goal && index + 1u < AGC_STEPS) return 1;
  if (mean > goal + 14u && index > 0u)                          return -1;  /* 亮且可退 */
  return 0;
}
