minimal:
	ocamlbuild minimal.otarget

all:
	ocamlbuild all.otarget

check: all
	ocamlbuild tests/sandbox.byte
	@_build/tests/sandbox.byte

clean:
	ocamlbuild -clean
	rm -f *~

tree: _build/tree.html

_build/tree.html: _build/_digests
	mkdir -p _build
	tree -o $@ -H '..'  -I '_build|_run|*~'

trustee-keygen:
	ocamlbuild src/bin/trustee-keygen.native
	@_build/src/bin/trustee-keygen.native
