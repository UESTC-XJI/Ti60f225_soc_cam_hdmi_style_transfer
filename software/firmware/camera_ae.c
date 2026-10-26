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
