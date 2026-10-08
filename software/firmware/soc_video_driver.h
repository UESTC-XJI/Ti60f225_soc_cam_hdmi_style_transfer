#pragma once
#include <stdint.h>
int osd_write_string(const char *text);
int osd_publish_metrics(void);
int camera_read_id(uint16_t *id);
int camera_verify_id(void);
int camera_init_cpu(void);
int camera_start(void);
int camera_stop(void);
int camera_recover(void);
