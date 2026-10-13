#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>

#define ABSTRACT_SOCKET_NAME "sobhan_x11_touch"

int main() {
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        fprintf(stderr, "[!] Cannot open X display for touch.\n");
        return 1;
    }

    int server_sock = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    addr.sun_path[0] = '\0';
    strncpy(addr.sun_path + 1, ABSTRACT_SOCKET_NAME, sizeof(addr.sun_path) - 2);

    socklen_t addr_len = sizeof(sa_family_t) + 1 + strlen(ABSTRACT_SOCKET_NAME);

    if (bind(server_sock, (struct sockaddr*)&addr, addr_len) < 0) {
        perror("[!] bind touch");
        return 1;
    }
    listen(server_sock, 1);
    printf("[+] Touch Server listening on abstract socket @%s...\n", ABSTRACT_SOCKET_NAME);

    unsigned char buf[9];
    while (1) {
        int client_sock = accept(server_sock, NULL, NULL);
        if (client_sock < 0) continue;
        printf("[+] Touch client connected.\n");

        while (1) {
            int read_bytes = 0;
            while (read_bytes < 9) {
                int r = read(client_sock, buf + read_bytes, 9 - read_bytes);
                if (r <= 0) goto client_disconnect;
                read_bytes += r;
            }

            int type = buf[0]; // 0: Down, 1: Move, 2: Up
            // Little-endian parsing for X and Y
            int x = buf[1] | (buf[2] << 8) | (buf[3] << 16) | (buf[4] << 24);
            int y = buf[5] | (buf[6] << 8) | (buf[7] << 16) | (buf[8] << 24);

            XTestFakeMotionEvent(display, -1, x, y, CurrentTime);
            if (type == 0) {
                XTestFakeButtonEvent(display, 1, True, CurrentTime);
            } else if (type == 2) {
                XTestFakeButtonEvent(display, 1, False, CurrentTime);
            }
            XFlush(display);
        }
client_disconnect:
        close(client_sock);
        printf("[-] Touch client disconnected.\n");
    }

    close(server_sock);
    XCloseDisplay(display);
    return 0;
}
