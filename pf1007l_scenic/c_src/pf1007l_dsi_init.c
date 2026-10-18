/*
 * pf1007l_dsi_init.c
 *
 * Allwinner A33 (sun8i) MIPI-DSI + D-PHY + TCON0 + Jadard JD9365DA (sq9365_101)
 * 800x1280 4-lane non-burst video mode hardware initializer for the AEEZO PF1007L.
 *
 * Ensures deterministic 60 FPS MIPI-DSI video scanout (RDDPM 0x0a = 0x1c DISON=1)
 * and PH0 PWM0 / PH6 backlight enable after Linux DRM allocates /dev/fb0.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#define DSI_BASE  0x01ca0000
#define DPHY_BASE 0x01ca1000
#define TCON_BASE 0x01c0c000
#define CCU_BASE  0x01c20000

struct lcd_cmd {
    uint16_t cmd;
    uint16_t count;
    uint8_t para;
};

static const struct lcd_cmd jd9365_init_table[] = {
    {0xe0, 1, 0x00},
    {0xe1, 1, 0x93},
    {0xe2, 1, 0x65},
    {0xe3, 1, 0xf8},
    {0x80, 1, 0x03},
    {0xe0, 1, 0x01},
    {0x00, 1, 0x00},
    {0x01, 1, 0x48},
    {0x0c, 1, 0x74},
    {0x17, 1, 0x00},
    {0x18, 1, 0xaf},
    {0x19, 1, 0x00},
    {0x1a, 1, 0x00},
    {0x1b, 1, 0xaf},
    {0x1c, 1, 0x00},
    {0x35, 1, 0x26},
    {0x37, 1, 0x09},
    {0x38, 1, 0x04},
    {0x39, 1, 0x00},
    {0x3a, 1, 0x01},
    {0x3c, 1, 0x78},
    {0x3d, 1, 0xff},
    {0x3e, 1, 0xff},
    {0x3f, 1, 0x7f},
    {0x40, 1, 0x06},
    {0x41, 1, 0xa0},
    {0x42, 1, 0x81},
    {0x43, 1, 0x14},
    {0x44, 1, 0x23},
    {0x45, 1, 0x28},
    {0x55, 1, 0x02},
    {0x57, 1, 0x69},
    {0x59, 1, 0x0a},
    {0x5a, 1, 0x2a},
    {0x5b, 1, 0x17},
    {0x5d, 1, 0x7f},
    {0x5e, 1, 0x6b},
    {0x5f, 1, 0x5c},
    {0x60, 1, 0x4f},
    {0x61, 1, 0x4d},
    {0x62, 1, 0x3f},
    {0x63, 1, 0x42},
    {0x64, 1, 0x2b},
    {0x65, 1, 0x44},
    {0x66, 1, 0x43},
    {0x67, 1, 0x43},
    {0x68, 1, 0x63},
    {0x69, 1, 0x52},
    {0x6a, 1, 0x5a},
    {0x6b, 1, 0x4f},
    {0x6c, 1, 0x4e},
    {0x6d, 1, 0x20},
    {0x6e, 1, 0x0f},
    {0x6f, 1, 0x00},
    {0x70, 1, 0x7f},
    {0x71, 1, 0x6b},
    {0x72, 1, 0x5c},
    {0x73, 1, 0x4f},
    {0x74, 1, 0x4d},
    {0x75, 1, 0x3f},
    {0x76, 1, 0x42},
    {0x77, 1, 0x2b},
    {0x78, 1, 0x44},
    {0x79, 1, 0x43},
    {0x7a, 1, 0x43},
    {0x7b, 1, 0x63},
    {0x7c, 1, 0x52},
    {0x7d, 1, 0x5a},
    {0x7e, 1, 0x4f},
    {0x7f, 1, 0x4e},
    {0x80, 1, 0x20},
    {0x81, 1, 0x0f},
    {0x82, 1, 0x00},
    {0xe0, 1, 0x02},
    {0x00, 1, 0x02},
    {0x01, 1, 0x02},
    {0x02, 1, 0x00},
    {0x03, 1, 0x00},
    {0x04, 1, 0x1e},
    {0x05, 1, 0x1e},
    {0x06, 1, 0x1f},
    {0x07, 1, 0x1f},
    {0x08, 1, 0x1f},
    {0x09, 1, 0x17},
    {0x0a, 1, 0x17},
    {0x0b, 1, 0x37},
    {0x0c, 1, 0x37},
    {0x0d, 1, 0x47},
    {0x0e, 1, 0x47},
    {0x0f, 1, 0x45},
    {0x10, 1, 0x45},
    {0x11, 1, 0x4b},
    {0x12, 1, 0x4b},
    {0x13, 1, 0x49},
    {0x14, 1, 0x49},
    {0x15, 1, 0x1f},
    {0x16, 1, 0x01},
    {0x17, 1, 0x01},
    {0x18, 1, 0x00},
    {0x19, 1, 0x00},
    {0x1a, 1, 0x1e},
    {0x1b, 1, 0x1e},
    {0x1c, 1, 0x1f},
    {0x1d, 1, 0x1f},
    {0x1e, 1, 0x1f},
    {0x1f, 1, 0x17},
    {0x20, 1, 0x17},
    {0x21, 1, 0x37},
    {0x22, 1, 0x37},
    {0x23, 1, 0x46},
    {0x24, 1, 0x46},
    {0x25, 1, 0x44},
    {0x26, 1, 0x44},
    {0x27, 1, 0x4a},
    {0x28, 1, 0x4a},
    {0x29, 1, 0x48},
    {0x2a, 1, 0x48},
    {0x2b, 1, 0x1f},
    {0x2c, 1, 0x01},
    {0x2d, 1, 0x01},
    {0x2e, 1, 0x00},
    {0x2f, 1, 0x00},
    {0x30, 1, 0x1f},
    {0x31, 1, 0x1f},
    {0x32, 1, 0x1e},
    {0x33, 1, 0x1e},
    {0x34, 1, 0x1f},
    {0x35, 1, 0x17},
    {0x36, 1, 0x17},
    {0x37, 1, 0x37},
    {0x38, 1, 0x37},
    {0x39, 1, 0x08},
    {0x3a, 1, 0x08},
    {0x3b, 1, 0x0a},
    {0x3c, 1, 0x0a},
    {0x3d, 1, 0x04},
    {0x3e, 1, 0x04},
    {0x3f, 1, 0x06},
    {0x40, 1, 0x06},
    {0x41, 1, 0x1f},
    {0x42, 1, 0x02},
    {0x43, 1, 0x02},
    {0x44, 1, 0x00},
    {0x45, 1, 0x00},
    {0x46, 1, 0x1f},
    {0x47, 1, 0x1f},
    {0x48, 1, 0x1e},
    {0x49, 1, 0x1e},
    {0x4a, 1, 0x1f},
    {0x4b, 1, 0x17},
    {0x4c, 1, 0x17},
    {0x4d, 1, 0x37},
    {0x4e, 1, 0x37},
    {0x4f, 1, 0x09},
    {0x50, 1, 0x09},
    {0x51, 1, 0x0b},
    {0x52, 1, 0x0b},
    {0x53, 1, 0x05},
    {0x54, 1, 0x05},
    {0x55, 1, 0x07},
    {0x56, 1, 0x07},
    {0x57, 1, 0x1f},
    {0x58, 1, 0x40},
    {0x5b, 1, 0x30},
    {0x5c, 1, 0x16},
    {0x5d, 1, 0x34},
    {0x5e, 1, 0x05},
    {0x5f, 1, 0x02},
    {0x63, 1, 0x00},
    {0x64, 1, 0x6a},
    {0x67, 1, 0x73},
    {0x68, 1, 0x1d},
    {0x69, 1, 0x08},
    {0x6a, 1, 0x6a},
    {0x6b, 1, 0x08},
    {0x6c, 1, 0x00},
    {0x6d, 1, 0x00},
    {0x6e, 1, 0x00},
    {0x6f, 1, 0x88},
    {0x75, 1, 0xff},
    {0x77, 1, 0xdd},
    {0x78, 1, 0x3f},
    {0x79, 1, 0x15},
    {0x7a, 1, 0x17},
    {0x7d, 1, 0x14},
    {0x7e, 1, 0x82},
    {0xe0, 1, 0x03},
    {0x9a, 1, 0xff},
    {0x9b, 1, 0xff},
    {0xaf, 1, 0x01},
    {0xe0, 1, 0x04},
    {0x00, 1, 0x0e},
    {0x02, 1, 0xb3},
    {0x09, 1, 0x61},
    {0x0e, 1, 0x48},
    {0x37, 1, 0x58},
    {0xe0, 1, 0x00},
    {0xe6, 1, 0x00},
    {0xe7, 1, 0x0c},
    {0x11, 1, 0x00},
    {0xff0, 120, 0},
    {0x29, 1, 0x00},
    {0xff0, 20, 0},
};

enum dsi_start_mode {
    DSI_START_LP11 = 0,
    DSI_START_TBA  = 1,
    DSI_START_HSTX = 2,
    DSI_START_LPTX = 3,
    DSI_START_LPRX = 4,
    DSI_START_HSC  = 5,
    DSI_START_HSD  = 6,
};

static uint8_t dsi_ecc_pro(uint32_t dsi_ph) {
    uint8_t d[24];
    for (int i = 0; i < 24; i++) d[i] = (dsi_ph >> i) & 1;
    uint8_t ecc = 0;
    ecc |= (d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23]) << 0;
    ecc |= (d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23]) << 1;
    ecc |= (d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22]) << 2;
    ecc |= (d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23]) << 3;
    ecc |= (d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23]) << 4;
    ecc |= (d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23]) << 5;
    return ecc;
}

static uint16_t dsi_crc_pro(const uint8_t *buf, uint32_t len) {
    uint16_t crc = 0xffff;
    for (uint32_t i = 0; i < len; i++) {
        uint8_t b = buf[i];
        for (int bit = 0; bit < 8; bit++) {
            if ((crc ^ b) & 1) crc = (crc >> 1) ^ 0x8408;
            else crc >>= 1;
            b >>= 1;
        }
    }
    return crc;
}

static uint16_t dsi_crc_repeat(uint8_t pd, uint32_t len) {
    uint16_t crc = 0xffff;
    for (uint32_t i = 0; i < len; i++) {
        uint8_t b = pd;
        for (int bit = 0; bit < 8; bit++) {
            if ((crc ^ b) & 1) crc = (crc >> 1) ^ 0x8408;
            else crc >>= 1;
            b >>= 1;
        }
    }
    return crc;
}

static uint32_t build_sync_pkt(uint8_t dt, uint8_t vc, uint8_t d0, uint8_t d1) {
    uint32_t val = (dt & 0x3f) | ((vc & 3) << 6) | ((uint32_t)d0 << 8) | ((uint32_t)d1 << 16);
    val |= (uint32_t)dsi_ecc_pro(val) << 24;
    return val;
}

static void dsi_start(volatile uint32_t *dsi, enum dsi_start_mode mode) {
    uint32_t jump_sel = 0x0000000f;
    switch (mode) {
        case DSI_START_LP11: jump_sel = 0x0000000f; break;
        case DSI_START_TBA:  jump_sel = 0x000000f1; break;
        case DSI_START_HSTX: jump_sel = 0x63f07602; break;
        case DSI_START_LPTX: jump_sel = 0x000f0004; break;
        case DSI_START_LPRX: jump_sel = 0x100700f4; break;
        case DSI_START_HSC:  jump_sel = 0x00000f02; break;
        case DSI_START_HSD:  jump_sel = 0x63f07006; break;
    }
    dsi[0x048 / 4] = jump_sel;
    dsi[0x010 / 4] &= ~1u;
    dsi[0x010 / 4] |= 1u;
    if (mode == DSI_START_HSC) {
        dsi[0x020 / 4] &= ~(1u << 4);
    }
}

static int dsi_wait_inst(volatile uint32_t *dsi) {
    for (int i = 0; i < 500; i++) {
        if ((dsi[0x010 / 4] & 1u) == 0) return 0;
        usleep(100);
    }
    dsi[0x010 / 4] &= ~1u;
    return -1;
}

static void dsi_dcs_wr(volatile uint32_t *dsi, uint8_t cmd, const uint8_t *para, uint32_t count) {
    volatile uint8_t *dsi8 = (volatile uint8_t *)dsi;
    dsi_wait_inst(dsi);
    if (count == 0) {
        dsi8[0x300] = 0x05;
        dsi8[0x301] = cmd;
        dsi8[0x302] = 0x00;
        uint32_t hdr = dsi[0x300 / 4] & 0x00ffffff;
        dsi8[0x303] = dsi_ecc_pro(hdr);
        dsi8[0x200] = 3;
    } else if (count == 1) {
        dsi8[0x300] = 0x15;
        dsi8[0x301] = cmd;
        dsi8[0x302] = para[0];
        uint32_t hdr = dsi[0x300 / 4] & 0x00ffffff;
        dsi8[0x303] = dsi_ecc_pro(hdr);
        dsi8[0x200] = 3;
    } else {
        uint16_t wc = count + 1;
        dsi8[0x300] = 0x39;
        dsi8[0x301] = wc & 0xff;
        dsi8[0x302] = (wc >> 8) & 0xff;
        uint32_t hdr = dsi[0x300 / 4] & 0x00ffffff;
        dsi8[0x303] = dsi_ecc_pro(hdr);
        dsi8[0x304] = cmd;
        for (uint32_t i = 0; i < count; i++) dsi8[0x305 + i] = para[i];
        uint8_t buf[64];
        buf[0] = cmd;
        for (uint32_t i = 0; i < count; i++) buf[1 + i] = para[i];
        uint16_t crc = dsi_crc_pro(buf, wc);
        dsi8[0x304 + wc] = crc & 0xff;
        dsi8[0x305 + wc] = (crc >> 8) & 0xff;
        dsi8[0x200] = count + 6;
    }
    dsi_start(dsi, DSI_START_LPTX);
    dsi_wait_inst(dsi);
}

static void ph_set(volatile uint32_t *pio, int pin, int val) {
    uint32_t cfg = pio[0x0fc / 4];
    cfg &= ~(0x7u << (pin * 4));
    cfg |=  (0x1u << (pin * 4));
    pio[0x0fc / 4] = cfg;
    if (val) pio[0x10c / 4] |= (1u << pin);
    else     pio[0x10c / 4] &= ~(1u << pin);
}

static void dsi_cfg_nonburst(volatile uint32_t *dsi) {
    dsi[0x000 / 4] = 0x00000001;
    dsi[0x010 / 4] = 0x00030000;
    dsi[0x060 / 4] = 0x0000000a;
    dsi[0x07c / 4] = 0x00000000;
    dsi[0x2f0 / 4] = 0x00300003;

    dsi[0x020 / 4] = 0x0000001f;
    dsi[0x024 / 4] = 0x10000001;
    dsi[0x028 / 4] = 0x20000010;
    dsi[0x02c / 4] = 0x2000000f;
    dsi[0x030 / 4] = 0x30100001;
    dsi[0x034 / 4] = 0x40000010;
    dsi[0x038 / 4] = 0x0000000f;
    dsi[0x03c / 4] = 0x5000001f;

    dsi[0x040 / 4] = 0x30000002;
    dsi[0x044 / 4] = 0x00310031;
    dsi[0x04c / 4] = 0x00560001;
    dsi[0x054 / 4] = 0x00310031;

    dsi[0x014 / 4] = (1295u << 4) | 0x7u;
    dsi[0x078 / 4] = 0x00000000;
    dsi[0x07c / 4] = 0x00000000;
    dsi[0x0f0 / 4] = 0x00000000;
    dsi[0x0f4 / 4] = 0x00000000;
    dsi[0x2f8 / 4] = 0x000000ff;

    dsi[0x080 / 4] = 0x00010008;
    dsi[0x090 / 4] = build_sync_pkt(0x3e, 0, (800 * 3) & 0xff, (800 * 3) >> 8);
    dsi[0x098 / 4] = 0x0000ffff;
    dsi[0x09c / 4] = 0xffffffff;

    dsi[0x00c / 4] = 0x00000000;
    dsi[0x0b0 / 4] = build_sync_pkt(0x21, 0, 0, 0);
    dsi[0x0b4 / 4] = build_sync_pkt(0x31, 0, 0, 0);
    dsi[0x0b8 / 4] = build_sync_pkt(0x01, 0, 0, 0);
    dsi[0x0bc / 4] = build_sync_pkt(0x11, 0, 0, 0);

    dsi[0x018 / 4] = (10u << 16) | 4u;
    dsi[0x01c / 4] = (1314u << 16) | 1280u;

    uint16_t hsa  = 18 * 3 - 10;
    uint16_t hbp  = (36 - 18) * 3 - 6;
    uint16_t hblk = (854 - 18) * 3 - 10;
    uint16_t hfp  = hblk - (800 * 3) - hbp - 12;
    uint16_t vblk = 4;

    dsi[0x0c0 / 4] = build_sync_pkt(0x19, 0, hsa & 0xff, hsa >> 8);
    dsi[0x0c4 / 4] = (uint32_t)dsi_crc_repeat(0, hsa) << 16;
    dsi[0x0c8 / 4] = build_sync_pkt(0x19, 0, hbp & 0xff, hbp >> 8);
    dsi[0x0cc / 4] = (uint32_t)dsi_crc_repeat(0, hbp) << 16;
    dsi[0x0d0 / 4] = build_sync_pkt(0x19, 0, hfp & 0xff, hfp >> 8);
    dsi[0x0d4 / 4] = (uint32_t)dsi_crc_repeat(0, hfp) << 16;
    dsi[0x0e0 / 4] = build_sync_pkt(0x19, 0, hblk & 0xff, hblk >> 8);
    dsi[0x0e4 / 4] = (uint32_t)dsi_crc_repeat(0, hblk) << 16;
    dsi[0x0e8 / 4] = build_sync_pkt(0x19, 0, vblk & 0xff, vblk >> 8);
    dsi[0x0ec / 4] = (uint32_t)dsi_crc_repeat(0, vblk) << 16;
}

int main(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    volatile uint32_t *dsi     = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DSI_BASE);
    volatile uint32_t *dphy    = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DPHY_BASE);
    volatile uint32_t *tcon    = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, TCON_BASE);
    volatile uint32_t *ccu_pio = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, CCU_BASE);
    if (dsi == MAP_FAILED || dphy == MAP_FAILED || tcon == MAP_FAILED || ccu_pio == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    volatile uint32_t *ccu = ccu_pio;
    volatile uint32_t *pio = ccu_pio + (0x800 / 4);

    /* 1. Hardware reset of MIPI-DSI + DPHY via CCU BUS_SOFT_RST_REG0 (0x2c0 bit 1) */
    tcon[0x040 / 4] &= ~(1u << 31);
    ccu[0x2c0 / 4] &= ~(1u << 1);
    usleep(1000);
    ccu[0x2c0 / 4] |= (1u << 1);
    usleep(1000);

    dsi_cfg_nonburst(dsi);

    /* 2. Configure D-PHY and analog TX lanes (matching A33 dphy_cfg + dsi_io_open) */
    dphy[0x000 / 4] = 0x00000030;
    dphy[0x004 / 4] = 0x10000000;
    dphy[0x010 / 4] = (10u << 24) | (6u << 16) | 14u;
    dphy[0x014 / 4] = (10u << 24) | (3u << 16) | (50u << 8) | 7u;
    dphy[0x018 / 4] = 30u;
    dphy[0x01c / 4] = 0u;
    dphy[0x020 / 4] = (3u << 8) | 3u;
    dphy[0x000 / 4] = 0x00000031;

    dphy[0x04c / 4] = (1u << 31) | (1u << 28) | (0xfu << 24) | (7u << 12) | (0xfu << 8);
    dphy[0x050 / 4] = (1u << 28) | (7u << 24);
    dphy[0x05c / 4] = (1u << 24) | (0xfu << 20) | (1u << 12) | (1u << 10) |
                      (1u << 8) | (1u << 6) | (1u << 4) | (1u << 2) | 1u;
    dphy[0x054 / 4] = (1u << 1);
    usleep(10);
    dphy[0x058 / 4] = (1u << 25) | (1u << 24) | (1u << 18);
    usleep(10);
    dphy[0x058 / 4] |= (0xfu << 28) | (1u << 27);
    usleep(10);
    dphy[0x058 / 4] |= (1u << 26);
    usleep(10);
    dphy[0x054 / 4] |= (1u << 4);
    usleep(10);
    dphy[0x050 / 4] |= (1u << 31);
    dphy[0x054 / 4] |= (0xfu << 24);

    dsi_start(dsi, DSI_START_LP11);
    dsi_wait_inst(dsi);
    usleep(10000);

    /* 3. Reset JD9365DA panel on PH7 and send 203 DCS init commands in LP11 */
    ph_set(pio, 7, 1); usleep(10000);
    ph_set(pio, 7, 0); usleep(20000);
    ph_set(pio, 7, 1); usleep(60000);
    ph_set(pio, 7, 1); usleep(10000);
    ph_set(pio, 7, 0); usleep(30000);
    ph_set(pio, 7, 1); usleep(30000);

    size_t num_cmds = sizeof(jd9365_init_table) / sizeof(jd9365_init_table[0]);
    for (size_t i = 0; i < num_cmds; i++) {
        if (jd9365_init_table[i].cmd == 0xff0) {
            usleep(jd9365_init_table[i].count * 1000);
        } else {
            uint8_t p = jd9365_init_table[i].para;
            dsi_dcs_wr(dsi, (uint8_t)jd9365_init_table[i].cmd, &p, jd9365_init_table[i].count);
        }
    }
    usleep(150000);

    /* 4. Start HS clock, wait 200ms, enable TCON0 TRI FIFO, and enter HSD video scanout */
    dsi_start(dsi, DSI_START_HSC);
    usleep(200000);

    tcon[0x000 / 4] = 0x80000000;
    tcon[0x048 / 4] = (799u << 16) | 1279u;
    tcon[0x0f8 / 4] = 0x00000008;
    tcon[0x160 / 4] = (441u << 16) | 799u;
    tcon[0x164 / 4] = 1279u;
    tcon[0x168 / 4] = (5460u << 16) | 10u;
    tcon[0x16c / 4] = 0x00000000;
    tcon[0x1f0 / 4] = (3000u << 16) | 3u;
    tcon[0x08c / 4] = 0x00000000;
    tcon[0x060 / 4] = 0x10010005;
    tcon[0x044 / 4] = 0xf0000004;
    tcon[0x040 / 4] = 0x81000000;

    dsi_start(dsi, DSI_START_HSD);
    usleep(50000);

    /* 5. Enable PH6 backlight power and mux PH0 to PWM0 (mux=2) */
    ph_set(pio, 6, 1);
    pio[0x0fc / 4] = (pio[0x0fc / 4] & ~0xfu) | 2u;

    close(fd);
    return 0;
}
