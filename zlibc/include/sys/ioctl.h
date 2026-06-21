#ifndef _SYS_IOCTL_H
#define _SYS_IOCTL_H

#define TIOCGWINSZ  0x5413
#define TIOCSWINSZ  0x5414
#define TIOCLINUX   0x541C
#define VT_GETSTATE 0x5603

struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};

int ioctl(int fd, unsigned long request, ...);

#endif /* _SYS_IOCTL_H */
