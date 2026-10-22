#pragma once
#include <stdint.h>
int osd_write_string(const char *text);
void osd_set_video_ready(uint32_t ready);
int osd_publish_metrics(void);
int camera_read_id(uint16_t *id);
int camera_verify_id(void);
int camera_init_cpu(void);
int camera_start(void);
int camera_stop(void);
int camera_recover(void);

int camera_reg_read(uint16_t reg,uint8_t *value);
int camera_reg_write(uint16_t reg,uint8_t value);
int osd_submit_string(const char *text);
int osd_submit_metrics(void);
int osd_poll(void);
