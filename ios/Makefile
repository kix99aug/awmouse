PROJECT   := awmouse.xcodeproj
LOCAL     := Config/Local.xcconfig
FRAMEWORK := Frameworks/Awmtunnel.xcframework
GOSRC     := $(shell find ../host/mobile/awmtunnel -name '*.go' -not -name '*_test.go') ../host/go.mod

# project.yml reads CURRENT_PROJECT_VERSION from this. Codemagic exports its
# own per-app counter, which `?=` leaves alone; everywhere else it is 1, since
# a local build never reaches TestFlight and has nothing to be unique against.
export BUILD_NUMBER ?= 1

ICON_SVG  := icon.svg
ICON_PNG  := awmouse/Assets.xcassets/AppIcon.appiconset/icon-1024.png

.PHONY: project open clean tunnel icon

## Rasterise icon.svg into the asset catalog. The SVG is the source; edit it,
## not the PNG. QuickLook renders it, then the alpha channel is stripped,
## because App Store Connect rejects icons that have one.
icon: $(ICON_PNG)

$(ICON_PNG): $(ICON_SVG) tools/flatten.swift
	$(eval TMP := $(shell mktemp -d))
	qlmanage -t -s 1024 -o $(TMP) $(ICON_SVG) >/dev/null 2>&1
	swift tools/flatten.swift $(TMP)/$(ICON_SVG).png $@
	rm -rf $(TMP)

## Regenerate the Xcode project from project.yml.
project: $(LOCAL) $(FRAMEWORK)
	xcodegen generate

## Bind the Go tunnel package into an xcframework. gomobile is a module tool
## of host/go.mod, so Go and Xcode are the only prerequisites. The output is
## gitignored; it is ~40 MB of WireGuard and gVisor.
tunnel: $(FRAMEWORK)

# gomobile finds gobind on PATH rather than through `go tool`, so install it
# first — without @version, `go install` takes the one pinned in go.mod.
$(FRAMEWORK): $(GOSRC)
	cd ../host && go install golang.org/x/mobile/cmd/gobind
	cd ../host && PATH="$$(go env GOPATH)/bin:$$PATH" go tool gomobile bind -target ios -iosversion 17.0 -o ../ios/$(FRAMEWORK) ./mobile/awmtunnel

## Seed the local signing config on a fresh checkout, so that generating the
## project never fails just because the gitignored file isn't there yet.
$(LOCAL):
	@cp Config/Local.xcconfig.example $@
	@echo "created $@ — set DEVELOPMENT_TEAM in it to build on a device"

open: project
	open $(PROJECT)

clean:
	rm -rf $(PROJECT) $(FRAMEWORK)
