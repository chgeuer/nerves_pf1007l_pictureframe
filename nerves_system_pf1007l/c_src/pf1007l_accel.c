/*
 * pf1007l_accel.c - Silan SC7A20 3-axis accelerometer daemon for PF1007L
 *
 * Reads 12-bit gravity vectors (X, Y, Z) at 0x19 on /dev/i2c-1 every 250ms
 * and streams "X Y Z\n" to stdout for Pf1007lScenic.Accelerometer.
 * Exits cleanly when stdin is closed by the Erlang Port.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>

#define SC7A20_ADDR      0x19
#define REG_WHO_AM_I     0x0F
#define REG_CTRL1        0x20
#define REG_CTRL4        0x23
#define REG_OUT_X_L_AUTO 0xA8

static int i2c_write_reg(int fd, uint8_t reg, uint8_t val) {
    uint8_t buf[2] = { reg, val };
    struct i2c_msg msg = {
        .addr = SC7A20_ADDR,
        .flags = 0,
        .len = 2,
        .buf = buf
    };
    struct i2c_rdwr_ioctl_data data = { .msgs = &msg, .nmsgs = 1 };
    return ioctl(fd, I2C_RDWR, &data);
}

static int i2c_read_regs(int fd, uint8_t reg, uint8_t *out, uint16_t len) {
    struct i2c_msg msgs[2] = {
        { .addr = SC7A20_ADDR, .flags = 0,        .len = 1,   .buf = &reg },
        { .addr = SC7A20_ADDR, .flags = I2C_M_RD, .len = len, .buf = out  }
    };
    struct i2c_rdwr_ioctl_data data = { .msgs = msgs, .nmsgs = 2 };
    return ioctl(fd, I2C_RDWR, &data);
}

int main(void) {
    int fd = open("/dev/i2c-1", O_RDWR);
    if (fd < 0) {
        perror("open /dev/i2c-1");
        return 1;
    }

    /* 50 Hz ODR, normal mode, Z/Y/X enabled */
    i2c_write_reg(fd, REG_CTRL1, 0x47);
    /* Block Data Update (BDU) + High Resolution +-2g */
    i2c_write_reg(fd, REG_CTRL4, 0x88);

    struct pollfd pfd = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP | POLLERR };

    while (1) {
        uint8_t raw[6] = {0};
        if (i2c_read_regs(fd, REG_OUT_X_L_AUTO, raw, 6) >= 0) {
            int16_t x = (int16_t)((raw[1] << 8) | raw[0]) >> 4;
            int16_t y = (int16_t)((raw[3] << 8) | raw[2]) >> 4;
            int16_t z = (int16_t)((raw[5] << 8) | raw[4]) >> 4;
            printf("%d %d %d\n", x, y, z);
            fflush(stdout);
        }

        int ret = poll(&pfd, 1, 250);
        if (ret > 0) {
            char discard[64];
            if (read(STDIN_FILENO, discard, sizeof(discard)) <= 0) {
                break;
            }
        }
    }

    close(fd);
    return 0;
}
