CC = gcc
CFLAGS = -Wall -Wextra -O2 -g
LDFLAGS = 

LIBRARY = libhealthcheck.a
TOOL = health_check_tool
TEST = test_health_check

LIB_SRCS = health_check.c
LIB_OBJS = $(LIB_SRCS:.c=.o)

TOOL_SRCS = health_check_tool.c
TOOL_OBJS = $(TOOL_SRCS:.c=.o)

TEST_SRCS = test_health_check.c
TEST_OBJS = $(TEST_SRCS:.c=.o)

all: $(LIBRARY) $(TOOL)

$(LIBRARY): $(LIB_OBJS)
	ar rcs $@ $^
	@echo "+ Built library: $@"

$(TOOL): $(TOOL_OBJS) $(LIBRARY)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "+ Built tool: $@"

$(TEST): $(TEST_OBJS) $(LIBRARY)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "+ Built test: $@"

%.o: %.c health_check.h
	$(CC) $(CFLAGS) -c $< -o $@

test: $(TEST)
	@echo "Running health check tests..."
	./$(TEST)

clean:
	rm -f $(LIB_OBJS) $(TOOL_OBJS) $(TEST_OBJS)
	rm -f $(LIBRARY) $(TOOL) $(TEST)
	rm -f /tmp/health.json /tmp/health_test.json
	@echo "+ Cleaned build artifacts"

install: $(LIBRARY) $(TOOL)
	install -d $(HOME)/ft-pac/lib
	install -d $(HOME)/ft-pac/include
	install -d $(HOME)/ft-pac/bin
	install -m 644 $(LIBRARY) $(HOME)/ft-pac/lib/
	install -m 644 health_check.h $(HOME)/ft-pac/include/
	install -m 755 $(TOOL) $(HOME)/ft-pac/bin/
	@echo "+ Installed to ~/ft-pac"

.PHONY: all test clean install

