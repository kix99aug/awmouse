PROJECT := AWMouse.xcodeproj
LOCAL   := Config/Local.xcconfig

.PHONY: project open clean

## Regenerate the Xcode project from project.yml.
project: $(LOCAL)
	xcodegen generate

## Seed the local signing config on a fresh checkout, so that generating the
## project never fails just because the gitignored file isn't there yet.
$(LOCAL):
	@cp Config/Local.xcconfig.example $@
	@echo "created $@ — set DEVELOPMENT_TEAM in it to build on a device"

open: project
	open $(PROJECT)

clean:
	rm -rf $(PROJECT)
