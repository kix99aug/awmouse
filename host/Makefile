APP_ID   := space.keybo.awmouse.host
VERSION  := 0.2
ICON     := ../ios/awmouse/Assets.xcassets/AppIcon.appiconset/icon-1024.png
DIST     := dist

# fyne's packager is a module tool of go.mod, like gomobile.
FYNE := go tool fyne

# "-" is ad-hoc: no certificate, no identity, but a proper bundle seal.
SIGN_IDENTITY ?= -

# Strip symbol and DWARF tables. WireGuard, gVisor and Fyne together make a
# large binary; this takes a third off, and nothing here is debugged with gdb.
LDFLAGS := -s -w

.PHONY: build run app windows test clean

## Build the host for this machine.
build:
	go build -ldflags "$(LDFLAGS)" -o $(DIST)/awmouse ./cmd/awmouse

run: build
	$(DIST)/awmouse

## macOS: a proper .app. It must be a bundle rather than a bare binary, or
## the Accessibility grant attaches to whatever launched it — a bare
## executable double-clicked in Finder runs inside Terminal, and it is
## Terminal that ends up in the permissions list.
app: build
	rm -rf $(DIST)/awmouse.app awmouse.app
	$(FYNE) package -os darwin \
		--executable $(DIST)/awmouse --name awmouse --app-id $(APP_ID) \
		--app-version $(VERSION) --icon $(ICON)
	mv awmouse.app $(DIST)/
	# Menu-bar utility: no Dock icon, no Cmd-Tab entry. Reach it from the tray.
	plutil -replace LSUIElement -bool true $(DIST)/awmouse.app/Contents/Info.plist
	# Seal the bundle. fyne package leaves only the linker's ad-hoc signature
	# on the executable, with no bundle signature or resource seal, and a
	# downloaded copy then fails Gatekeeper as "damaged" — a verdict with no
	# way past. An ad-hoc bundle signature turns that into the ordinary
	# unidentified-developer refusal, which System Settings can override.
	# Set SIGN_IDENTITY to a "Developer ID Application" identity to sign for
	# real; notarisation is still a separate step.
	codesign --force --deep --sign "$(SIGN_IDENTITY)" \
		--identifier $(APP_ID) --options runtime $(DIST)/awmouse.app
	@echo "built $(DIST)/awmouse.app"

## Windows, cross-compiled from macOS. Fyne needs cgo, so this needs a C
## cross-compiler: `brew install mingw-w64`. -H=windowsgui keeps a console
## window from opening behind the app.
windows:
	CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc \
		go build -ldflags "$(LDFLAGS) -H=windowsgui" -o $(DIST)/awmouse.exe ./cmd/awmouse

test:
	go vet ./...
	go test ./...

clean:
	rm -rf $(DIST)
