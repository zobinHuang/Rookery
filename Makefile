.PHONY: build app run install icon test chrome-extension clean

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
	scripts/bundle-app.sh release

run: app
	open .build/Rookery.app

# Install into /Applications, quitting a running copy first so the new build is the one that opens. The app
# was called MuxShots before; that copy is quit and removed too, so it cannot put windows back over Rookery's.
install: app
	-osascript -e 'quit app "Rookery"'
	-osascript -e 'quit app "MuxShots"'
	while pgrep -x Rookery > /dev/null || pgrep -x MuxShots > /dev/null; do sleep 0.2; done
	rm -rf /Applications/Rookery.app /Applications/MuxShots.app
	cp -R .build/Rookery.app /Applications/Rookery.app
	open /Applications/Rookery.app

icon:
	swiftc -o .build/make-icon scripts/make-icon.swift
	.build/make-icon .build
	iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns

test:
	swift test $(TEST_FLAGS)

# Build the Chrome extension into extensions/chrome/dist, to load unpacked from chrome://extensions.
chrome-extension:
	cd extensions/chrome && npm ci && npm run build

clean:
	rm -rf .build
