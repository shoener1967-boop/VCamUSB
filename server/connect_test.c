// connect_test — testet ob ein TCP-Port auf 127.0.0.1 offen ist
// usage: connect_test <port>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <port>\n", argv[0]); return 2; }
    int port = atoi(argv[1]);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 2; }
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        printf("PORT %d OPEN\n", port);
        close(fd);
        return 0;
    }
    printf("PORT %d CLOSED\n", port);
    close(fd);
    return 1;
}
