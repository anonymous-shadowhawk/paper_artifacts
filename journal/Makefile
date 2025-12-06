CC = gcc
CFLAGS = -Wall -Wextra -O2 -g
LDFLAGS = 

LIBRARY = libbootjournal.a
TEST = test_journal
DEMO = demo_journal
TOOL = journal_tool

LIB_SRCS = boot_journal.c
LIB_OBJS = $(LIB_SRCS:.c=.o)

TEST_SRCS = test_journal.c
TEST_OBJS = $(TEST_SRCS:.c=.o)

DEMO_SRCS = demo_journal.c
DEMO_OBJS = $(DEMO_SRCS:.c=.o)

TOOL_SRCS = journal_tool.c
TOOL_OBJS = $(TOOL_SRCS:.c=.o)

all: $(LIBRARY) $(TEST) $(DEMO) $(TOOL)

$(LIBRARY): $(LIB_OBJS)
	ar rcs $@ $^
	@echo "+ Built library: $@"

$(TEST): $(TEST_OBJS) $(LIBRARY)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "+ Built test program: $@"

$(DEMO): $(DEMO_OBJS) $(LIBRARY)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "+ Built demo program: $@"

$(TOOL): $(TOOL_OBJS) $(LIBRARY)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "+ Built command-line tool: $@"

%.o: %.c boot_journal.h
	$(CC) $(CFLAGS) -c $< -o $@

test: $(TEST)
	@echo "Running test suite..."
	./$(TEST)

demo: $(DEMO)
	@echo "Running demo..."
	./$(DEMO)

clean:
	rm -f $(LIB_OBJS) $(TEST_OBJS) $(DEMO_OBJS) $(TOOL_OBJS)
	rm -f $(LIBRARY) $(TEST) $(DEMO) $(TOOL)
	rm -f /tmp/test_boot_journal.dat
	rm -f /tmp/demo_journal.dat
	@echo "+ Cleaned build artifacts"

install: $(LIBRARY)
	install -d $(HOME)/ft-pac/lib
	install -d $(HOME)/ft-pac/include
	install -m 644 $(LIBRARY) $(HOME)/ft-pac/lib/
	install -m 644 boot_journal.h $(HOME)/ft-pac/include/
	@echo "+ Installed to ~/ft-pac/{lib,include}"

.PHONY: all test demo clean install

