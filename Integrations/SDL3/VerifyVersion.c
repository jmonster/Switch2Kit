/* Build diagnostic only: use the host SDL target without starting any subsystem. */
#include <SDL3/SDL_version.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    long expected = SDL_VERSION;
    if (argc > 2) {
        fputs("Usage: SDLVersion [numeric-version]\n", stderr);
        return 2;
    }
    if (argc == 2) {
        char *end = NULL;
        errno = 0;
        expected = strtol(argv[1], &end, 10);
        if (errno || end == argv[1] || *end || expected <= 0 || expected > INT_MAX) {
            fputs("Invalid expected SDL version\n", stderr);
            return 2;
        }
    }
    const int runtime = SDL_GetVersion();
    const char *revision = SDL_GetRevision();
    printf("SDL headers=%d runtime=%d revision=%.160s\n", SDL_VERSION, runtime,
           revision ? revision : "");
    if (SDL_VERSION != expected || runtime != expected) {
        fprintf(stderr, "SDL version mismatch; expected %ld\n", expected);
        return 1;
    }
    return 0;
}
