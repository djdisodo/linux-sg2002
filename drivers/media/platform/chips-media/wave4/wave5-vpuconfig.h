/* SPDX-License-Identifier: (GPL-2.0 OR BSD-3-Clause) */
/*
 * Wave4 codec IP - product config definitions
 *
 * Copyright (C) 2021-2023 CHIPS&MEDIA INC
 */

#ifndef _VPU_CONFIG_H_
#define _VPU_CONFIG_H_

#define W4_PRODUCT_CODE			0x4201

#define W4_ENC_WORKBUF_SIZE             (128 * 1024)      //HEVC 128K, AVC 40K
#define W4_DEC_WORKBUF_SIZE             (3 * 1024 * 1024)

#define MAX_NUM_INSTANCE                32

#define W5_DEF_DEC_PIC_WIDTH            720U
#define W5_DEF_DEC_PIC_HEIGHT           480U
#define W5_MIN_DEC_PIC_8_WIDTH          8U
#define W5_MIN_DEC_PIC_8_HEIGHT         8U
#define W5_MIN_DEC_PIC_32_WIDTH         32U
#define W5_MIN_DEC_PIC_32_HEIGHT        32U
#define W5_MAX_DEC_PIC_WIDTH            8192U
#define W5_MAX_DEC_PIC_HEIGHT           4320U
#define W5_DEC_CODEC_STEP_WIDTH         1U
#define W5_DEC_CODEC_STEP_HEIGHT        1U
#define W5_DEC_RAW_STEP_WIDTH           32U
#define W5_DEC_RAW_STEP_HEIGHT          16U

#define W5_DEF_ENC_PIC_WIDTH            416U
#define W5_DEF_ENC_PIC_HEIGHT           240U
#define W5_MIN_ENC_PIC_WIDTH            256U
#define W5_MIN_ENC_PIC_HEIGHT           128U
#define W5_MAX_ENC_PIC_WIDTH            8192U
#define W5_MAX_ENC_PIC_HEIGHT           8192U
#define W5_ENC_CODEC_STEP_WIDTH         8U
#define W5_ENC_CODEC_STEP_HEIGHT        8U
#define W5_ENC_RAW_STEP_WIDTH           32U
#define W5_ENC_RAW_STEP_HEIGHT          16U

//  application specific configuration
#define VPU_ENC_TIMEOUT                 60000
#define VPU_DEC_TIMEOUT                 60000
#define VPU_DEC_STOP_TIMEOUT            10

// for WAVE encoder
#define USE_SRC_PRP_AXI         0
#define USE_SRC_PRI_AXI         1
#define DEFAULT_SRC_AXI         USE_SRC_PRP_AXI

/************************************************************************/
/* VPU COMMON MEMORY                                                    */
/************************************************************************/
#define VLC_BUF_NUM                     (2)

#define W4_COMMAND_QUEUE_DEPTH		(2)

#define W5_REMAP_INDEX0                 0
#define W5_REMAP_INDEX1                 1
#define W5_REMAP_MAX_SIZE               (1024 * 1024)

#define W4_MAX_CODE_BUF_SIZE            (256 * 1024)
#define WAVE5_TEMPBUF_SIZE              (1024 * 1024)
#define W4_TEMPBUF_SIZE                 (512 * 1024)

#define W4_SIZE_COMMON                  (W4_MAX_CODE_BUF_SIZE + W4_TEMPBUF_SIZE)

//=====4. VPU REPORT MEMORY  ======================//

#define WAVE5_UPPER_PROC_AXI_ID     0x0

#define WAVE5_PROC_AXI_ID           0x0
#define WAVE5_PRP_AXI_ID            0x0
#define WAVE5_FBD_Y_AXI_ID          0x0
#define WAVE5_FBC_Y_AXI_ID          0x0
#define WAVE5_FBD_C_AXI_ID          0x0
#define WAVE5_FBC_C_AXI_ID          0x0
#define WAVE5_SEC_AXI_ID            0x0
#define WAVE5_PRI_AXI_ID            0x0

#endif  /* _VPU_CONFIG_H_ */
