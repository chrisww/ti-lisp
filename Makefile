.PHONY: all test clean

SRC_FILES = ast.ml irgen.ml macro.ml parser.mly sast.ml scanner.mll semant.ml symtable.ml tilisp.ml utils.ml
TEST_FILES = testing.ml

all: tilisp.native testing.native libtilisp.a

tilisp.native: $(SRC_FILES)
	ocamlbuild -no-hygiene -package llvm tilisp.native

testing.native: $(TEST_FILES)
	ocamlbuild -lib unix testing.native

tilisp.o: tilisp.h tilisp.cpp
	g++ tilisp.cpp -c -o tilisp.o

libtilisp.a: tilisp.o
	ar -crs libtilisp.a tilisp.o
	ranlib libtilisp.a

test: testing.native libtilisp.a
	./testing.native

clean:
	rm -rf *.o *.a *.ll _build *.native
