.PHONY: build app run test clean

# Swift Testing ships outside the default search paths when only the Command Line Tools are installed.
DEVELOPER_DIR := $(shell xcode-select -p)
ifeq ($(DEVELOPER_DIR),/Library/Developer/CommandLineTools)
TESTING_FRAMEWORKS := $(DEVELOPER_DIR)/Library/Developer/Frameworks
TESTING_LIBRARIES := $(DEVELOPER_DIR)/Library/Developer/usr/lib
TEST_FLAGS := -Xswiftc -F$(TESTING_FRAMEWORKS) -Xlinker -F$(TESTING_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(TESTING_FRAMEWORKS) -Xlinker -rpath -Xlinker $(TESTING_LIBRARIES)
endif

build:
	swift build

app:
	scripts/bundle-app.sh debug

run: app
	open .build/MuxShots.app

test:
	swift test $(TEST_FLAGS)

clean:
	rm -rf .build
