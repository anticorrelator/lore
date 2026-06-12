package work

// Link inputs for the libghostty terminal backend. The vendored SIMD-off
// static archives and headers under libghostty/ (provenance in
// libghostty/MANIFEST.json) are wired here via cgo so builds need only a
// C compiler — no Zig, CMake, pkg-config, or network fetch.
//
// go.mitchellh.com/libghostty's own compile step resolves headers through a
// `#cgo pkg-config: libghostty-vt-static` directive; export
// PKG_CONFIG=libghostty/pkg-config-shim.sh to satisfy it (install.sh and
// `lore rebuild` do this automatically).

/*
#cgo CFLAGS: -I${SRCDIR}/libghostty/include
#cgo darwin,arm64 LDFLAGS: -L${SRCDIR}/libghostty/lib/darwin_arm64 -lghostty-vt
#cgo darwin,amd64 LDFLAGS: -L${SRCDIR}/libghostty/lib/darwin_amd64 -lghostty-vt
#cgo linux,amd64 LDFLAGS: -L${SRCDIR}/libghostty/lib/linux_amd64 -lghostty-vt
*/
import "C"
