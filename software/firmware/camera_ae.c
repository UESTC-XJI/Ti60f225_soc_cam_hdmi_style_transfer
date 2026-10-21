#include "camera_3a.h"
/* Highlights soften the metering goal rather than unconditionally darkening
 * an already dark scene. The bounded continuous goal avoids two competing
 * increase/decrease loops around a hard saturation threshold. */
uint32_t camera_ae_goal(uint32_t high) {
  uint32_t reduction=high>10?(high-10)/4u:0;
  return 96u-(reduction>24u?24u:reduction);
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
