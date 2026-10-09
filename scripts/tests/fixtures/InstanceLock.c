#include <sys/file.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int fd = open(argv[1], O_CREAT | O_RDWR, 0600);
    if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) return 3;
    puts("locked"); fflush(stdout);
    for (;;) pause();
}
