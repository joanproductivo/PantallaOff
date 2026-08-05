APP        = PantallaOff
BUNDLE     = build/$(APP).app
BIN        = build
SDK       := $(shell xcrun --show-sdk-path)
TARGET     = arm64-apple-macos13.0

CC         = clang
CFLAGS     = -Wall -Wextra -O2 -fstack-protector-strong -mmacosx-version-min=13.0
FRAMEWORKS = -framework ApplicationServices -framework CoreGraphics

SWIFTC     = swiftc
SWIFTFLAGS = -sdk $(SDK) -target $(TARGET) -O \
             -import-objc-header src/Bridge.h

CORE_SRC   = src/PantallaCore.c
CORE_OBJ   = $(BIN)/PantallaCore.o
SWIFT_SRC  = src/DisplayControl.swift src/LoginItem.swift src/KeepAwake.swift src/AppDelegate.swift src/main.swift

.PHONY: all tools app bundle sign install uninstall clean probe status help rescue selftest icon

help:
	@echo "PantallaOff — objetivos disponibles:"
	@echo "  make tools     compila probe, rescue y selftest en ./build"
	@echo "  make all       tools + la app + el bundle firmado"
	@echo "  make install   instala ~/rescue y /Applications/$(APP).app"
	@echo "  make probe     ejecuta la sonda de SOLO LECTURA"
	@echo "  make status    estado actual + dead-man (solo lectura)"
	@echo "  make clean"
	@echo ""
	@echo "IMPORTANTE: valida siempre contra el monitor EXTERNO antes de tocar"
	@echo "la pantalla interna. Ver README.md."

all: tools bundle

$(BIN):
	@mkdir -p $(BIN)

$(CORE_OBJ): $(CORE_SRC) src/PantallaCore.h | $(BIN)
	$(CC) $(CFLAGS) -c $(CORE_SRC) -o $@

tools: $(BIN)/probe $(BIN)/rescue $(BIN)/selftest

$(BIN)/probe: tools/probe.c $(CORE_OBJ) | $(BIN)
	$(CC) $(CFLAGS) $< $(CORE_OBJ) $(FRAMEWORKS) -o $@

$(BIN)/rescue: tools/rescue.c $(CORE_OBJ) | $(BIN)
	$(CC) $(CFLAGS) $< $(CORE_OBJ) $(FRAMEWORKS) -o $@

$(BIN)/selftest: tools/selftest.c $(CORE_OBJ) | $(BIN)
	$(CC) $(CFLAGS) $< $(CORE_OBJ) $(FRAMEWORKS) -o $@

app: $(BIN)/$(APP)

$(BIN)/$(APP): $(SWIFT_SRC) $(CORE_OBJ) src/Bridge.h | $(BIN)
	$(SWIFTC) $(SWIFTFLAGS) $(SWIFT_SRC) $(CORE_OBJ) \
	    -framework AppKit -framework ServiceManagement $(FRAMEWORKS) -o $@

bundle: $(BIN)/$(APP) $(BIN)/rescue resources/Info.plist resources/AppIcon.icns
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp $(BIN)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	@# rescue viaja DENTRO del bundle: el dead-man debe existir allá donde
	@# esté la app, no depender de que ~/rescue esté instalado.
	@cp $(BIN)/rescue $(BUNDLE)/Contents/MacOS/rescue
	@cp resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@$(MAKE) --no-print-directory sign
	@echo "bundle listo: $(BUNDLE)"

sign:
	@codesign --force --sign - --timestamp=none $(BUNDLE)/Contents/MacOS/rescue
	@codesign --force --sign - --timestamp=none $(BUNDLE)
	@echo "firmado ad-hoc (sin entitlements; no habrá aviso de Gatekeeper"
	@echo "porque un binario compilado localmente no lleva xattr de cuarentena)"

# ~/rescue: ruta corta a propósito, para poder teclearla a ciegas o por SSH.
install: tools bundle
	@cp $(BIN)/rescue $(HOME)/rescue
	@chmod +x $(HOME)/rescue
	@rm -rf /Applications/$(APP).app
	@cp -R $(BUNDLE) /Applications/
	@echo "instalado:"
	@echo "  ~/rescue"
	@echo "  /Applications/$(APP).app"
	@echo ""
	@echo "Comprueba AHORA que el rescate funciona por SSH, antes de apagar nada:"
	@echo "  ssh $(USER)@<esta-mac> '~/rescue --status'"

uninstall:
	@rm -f $(HOME)/rescue
	@rm -rf /Applications/$(APP).app
	@echo "desinstalado (el fichero de estado ~/.pantallaoff-state se conserva)"

probe: $(BIN)/probe
	@$(BIN)/probe

status: $(BIN)/rescue
	@$(BIN)/rescue --status

clean:
	@rm -rf $(BIN)

# Alias con nombre, para poder hacer "make rescue" y "make selftest".
rescue: $(BIN)/rescue
selftest: $(BIN)/selftest

# El icono se dibuja por código: se versiona como fuente, no como binario opaco.
icon:
	swift tools/make-icon.swift resources/AppIcon.icns

resources/AppIcon.icns: tools/make-icon.swift
	swift tools/make-icon.swift $@
