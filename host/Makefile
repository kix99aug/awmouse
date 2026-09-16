APP_ID   := space.keybo.awmouse.host
VERSION  := 0.2
ICON     := ../ios/awmouse/Assets.xcassets/AppIcon.appiconset/icon-1024.png
DIST     := dist

# fyne's packager is a module tool of go.mod, like gomobile.
FYNE := go tool fyne

# "-" is ad-hoc: no certificate, no identity, but a proper bundle seal. Set
# to a "Developer ID Application: …" identity to sign for distribution.
SIGN_IDENTITY ?= -

# A secure timestamp is required for notarisation and impossible for ad-hoc.
SIGN_FLAGS := $(if $(filter -,$(SIGN_IDENTITY)),,--timestamp)

# Notarisation credentials: an App Store Connect API key, either as a
# notarytool keychain profile (`xcrun notarytool store-credentials <name>`
# once, then NOTARY_PROFILE=<name>) or as the key file plus its IDs. On
# Codemagic the latter come from the app_store_connect integration.
NOTARY_PROFILE ?=
NOTARY_KEY     ?= $(HOME)/.private_keys/AuthKey.p8
NOTARY_KEY_ID  ?=
NOTARY_ISSUER  ?=
NOTARY_AUTH := $(if $(NOTARY_PROFILE),--keychain-profile "$(NOTARY_PROFILE)",--key "$(NOTARY_KEY)" --key-id "$(NOTARY_KEY_ID)" --issuer "$(NOTARY_ISSUER)")

# Strip symbol and DWARF tables. WireGuard, gVisor and Fyne together make a
# large binary; this takes a third off, and nothing here is debugged with gdb.
LDFLAGS := -s -w

.PHONY: build run app zip notarize windows test clean

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
	codesign --force --deep --sign "$(SIGN_IDENTITY)" $(SIGN_FLAGS) \
		--identifier $(APP_ID) --options runtime $(DIST)/awmouse.app
	@echo "built $(DIST)/awmouse.app (signed as: $(SIGN_IDENTITY))"

## Zip the bundle. A .app is a directory; ditto keeps the bundle intact.
zip:
	rm -f $(DIST)/awmouse-macos.zip
	cd $(DIST) && ditto -c -k --keepParent awmouse.app awmouse-macos.zip

## Notarise and staple. Only meaningful after `make app` with a Developer ID
## identity: Apple's service rejects ad-hoc signatures outright. Stapling
## attaches the ticket to the bundle so Gatekeeper can verify it offline;
## the zip is then remade around the stapled bundle.
notarize: zip
	xcrun notarytool submit $(DIST)/awmouse-macos.zip $(NOTARY_AUTH) --wait --timeout 20m
	xcrun stapler staple $(DIST)/awmouse.app
	$(MAKE) zip
	# What a downloaded copy will face: this must say accepted.
	spctl --assess --type execute -v $(DIST)/awmouse.app

## Windows, cross-compiled from macOS. Fyne needs cgo, so this needs a C
## cross-compiler: `brew install mingw-w64`. -H=windowsgui keeps a console
## window from opening behind the app.
windows:
	CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc \
		go build -ldflags "$(LDFLAGS) -H=windowsgui" -o $(DIST)/awmouse.exe ./cmd/awmouse
	rm -f $(DIST)/awmouse-win.zip
	cd $(DIST) && zip -q awmouse-win.zip awmouse.exe

test:
	go vet ./...
	go test ./...

clean:
	rm -rf $(DIST)
