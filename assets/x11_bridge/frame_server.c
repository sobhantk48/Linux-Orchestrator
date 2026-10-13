#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>

#define ABSTRACT_SOCKET_NAME "sobhan_x11_frame"

int main(int argc, char *argv[]) {
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        fprintf(stderr, "[!] Cannot open X display.\n");
        return 1;
    }

    Window root = DefaultRootWindow(display);
    XWindowAttributes gwa;
    XGetWindowAttributes(display, root, &gwa);
    int width = gwa.width;
    int height = gwa.height;

    int server_sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_sock < 0) {
        perror("[!] socket");
        return 1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    // Abstract socket: First byte is null '\0'
    addr.sun_path[0] = '\0';
    strncpy(addr.sun_path + 1, ABSTRACT_SOCKET_NAME, sizeof(addr.sun_path) - 2);

    socklen_t addr_len = sizeof(sa_family_t) + 1 + strlen(ABSTRACT_SOCKET_NAME);

    if (bind(server_sock, (struct sockaddr*)&addr, addr_len) < 0) {
        perror("[!] bind");
        close(server_sock);
        return 1;
    }

    if (listen(server_sock, 1) < 0) {
        perror("[!] listen");
        close(server_sock);
        return 1;
    }

    printf("[+] X11 Frame Server listening on abstract socket @%s (%dx%d)...\n", ABSTRACT_SOCKET_NAME, width, height);

    unsigned char *rgba_buf = (unsigned char *)malloc(width * height * 4);
    if (!rgba_buf) {
        fprintf(stderr, "[!] Out of memory.\n");
        close(server_sock);
        return 1;
    }

    while (1) {
        int client_sock = accept(server_sock, NULL, NULL);
        if (client_sock < 0) {
            perror("[!] accept");
            continue;
        }
        printf("[+] Native client connected.\n");

        int header[2] = {width, height};
        if (write(client_sock, header, sizeof(header)) <= 0) {
            close(client_sock);
            continue;
        }

        while (1) {
            XImage *image = XGetImage(display, root, 0, 0, width, height, AllPlanes, ZPixmap);
            if (!image) {
                break;
            }

            // Convert BGRA (X11) to RGBA (Android)
            const unsigned char *src = (const unsigned char *)image->data;
            unsigned char *dst = rgba_buf;
            int total_pixels = width * height;

            for (int i = 0; i < total_pixels; i++) {
                dst[0] = src[2]; // R <- B
                dst[1] = src[1]; // G <- G
                dst[2] = src[0]; // B <- R
                dst[3] = 0xFF;   // A
                src += 4;
                dst += 4;
            }

            int data_size = total_pixels * 4;
            ssize_t written = write(client_sock, rgba_buf, data_size);
            XDestroyImage(image);

            if (written <= 0) {
                printf("[-] Native client disconnected.\n");
                break;
            }
            usleep(16000); // ~60 FPS
        }
        close(client_sock);
    }

    free(rgba_buf);
    close(server_sock);
    XCloseDisplay(display);
    return 0;
}
