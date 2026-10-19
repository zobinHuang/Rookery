.PHONY: build app run clean

build:
	swift build

app:
	scripts/bundle-app.sh debug

run: app
	open .build/MuxShots.app

clean:
	rm -rf .build
