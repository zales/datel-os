CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -std=gnu11
LDLIBS += -lpthread

OBJS = k1os-stream.o helix.o overlay.o moonraker.o graph.o sysstat.o

all: k1os-stream

k1os-stream: $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

k1os-stream.o: k1os-stream.c helix.h overlay.h moonraker.h graph.h jpeg_dht.h sysstat.h
helix.o: helix.c helix.h
overlay.o: overlay.c overlay.h font12x24.h font16x32.h
moonraker.o: moonraker.c moonraker.h
graph.o: graph.c graph.h overlay.h moonraker.h sysstat.h
sysstat.o: sysstat.c sysstat.h

clean:
	rm -f $(OBJS) k1os-stream

.PHONY: all clean
