#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>

#define SOCKET_PATH "/tmp/sobhan_x11_touch"

// Packet: [type (1B)][data1 (4B)][data2 (4B)] -> Total 9 Bytes
// type 0: Motion (x=data1, y=data2)
// type 1: Button Press (button=data1)
// type 2: Button Release (button=data1)
// type 3: Key Press (keysym=data1)
// type 4: Key Release (keysym=data1)

int main() {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "[-] Cannot open display :0\n");
        return 1;
    }

    int server_fd, client_fd;
    struct sockaddr_un addr;

    unlink(SOCKET_PATH);
    server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("[-] socket");
        return 1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("[-] bind");
        return 1;
    }

    listen(server_fd, 5);
    printf("[+] Input server (touch + keyboard) listening on %s\n", SOCKET_PATH);

    while (1) {
        client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) continue;

        unsigned char buf[9];
        while (read(client_fd, buf, 9) == 9) {
            unsigned char type = buf[0];
            int d1 = (buf[1] << 24) | (buf[2] << 16) | (buf[3] << 8) | buf[4];
            int d2 = (buf[5] << 24) | (buf[6] << 16) | (buf[7] << 8) | buf[8];

            if (type == 0) {
                // Motion
                XTestFakeMotionEvent(dpy, 0, d1, d2, CurrentTime);
            } else if (type == 1) {
                // Mouse Press
                XTestFakeButtonEvent(dpy, d1, True, CurrentTime);
            } else if (type == 2) {
                // Mouse Release
                XTestFakeButtonEvent(dpy, d1, False, CurrentTime);
            } else if (type == 3) {
                // Key Press
                KeyCode kc = XKeysymToKeycode(dpy, (KeySym)d1);
                if (kc) XTestFakeKeyEvent(dpy, kc, True, CurrentTime);
            } else if (type == 4) {
                // Key Release
                KeyCode kc = XKeysymToKeycode(dpy, (KeySym)d1);
                if (kc) XTestFakeKeyEvent(dpy, kc, False, CurrentTime);
            }
            XFlush(dpy);
        }
        close(client_fd);
    }

    XCloseDisplay(dpy);
    return 0;
}
