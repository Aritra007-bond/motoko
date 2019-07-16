{ nixpkgs ? (import ./nix/nixpkgs.nix).nixpkgs {},
  test-dvm ? true,
  dvm ? null,
  export-shell ? false,
}:

let llvm = import ./nix/llvm.nix { system = nixpkgs.system; }; in

let stdenv = nixpkgs.stdenv; in

let subpath = p: import ./nix/gitSource.nix p; in

let ocaml_wasm = import ./nix/ocaml-wasm.nix {
  inherit (nixpkgs) stdenv fetchFromGitHub ocaml;
  inherit (nixpkgs.ocamlPackages) findlib ocamlbuild;
}; in

let ocaml_vlq = import ./nix/ocaml-vlq.nix {
  inherit (nixpkgs) stdenv fetchFromGitHub ocaml dune;
  inherit (nixpkgs.ocamlPackages) findlib;
}; in

let ocaml_bisect_ppx = import ./nix/ocaml-bisect_ppx.nix nixpkgs; in
let ocaml_bisect_ppx-ocamlbuild = import ./nix/ocaml-bisect_ppx-ocamlbuild.nix nixpkgs; in

let dev = import (builtins.fetchGit {
  url = "ssh://git@github.com/dfinity-lab/dev";
  ref = "master";
  rev = "fcd387ce757fcc1ee697a19665ada9bc3f453adc";
}) { system = nixpkgs.system; }; in

# Include dvm
let real-dvm =
  if dvm == null
  then if test-dvm
    then dev.dvm
    else null
  else dvm; in

# Include js-client
let js-client = dev.js-dfinity-client; in

let commonBuildInputs = [
  nixpkgs.ocaml
  nixpkgs.dune
  nixpkgs.ocamlPackages.atdgen
  nixpkgs.ocamlPackages.findlib
  nixpkgs.ocamlPackages.menhir
  nixpkgs.ocamlPackages.num
  nixpkgs.ocamlPackages.stdint
  ocaml_wasm
  ocaml_vlq
  nixpkgs.ocamlPackages.zarith
  nixpkgs.ocamlPackages.yojson
  nixpkgs.ocamlPackages.ppxlib
  nixpkgs.ocamlPackages.ppx_inline_test
  ocaml_bisect_ppx
  ocaml_bisect_ppx-ocamlbuild
  nixpkgs.ocamlPackages.ocaml-migrate-parsetree
  nixpkgs.ocamlPackages.ppx_tools_versioned
]; in

let
  libtommath = nixpkgs.fetchFromGitHub {
    owner = "libtom";
    repo = "libtommath";
    rev = "9e1a75cfdc4de614eaf4f88c52d8faf384e54dd0";
    sha256 = "0qwmzmp3a2rg47pnrsls99jpk5cjj92m75alh1kfhcg104qq6w3d";
  };

  llvmBuildInputs = [
    llvm.clang_9
    llvm.lld_9
  ];

  llvmEnv = ''
    export CLANG="clang-9"
    export WASM_LD=wasm-ld
  '';
in

rec {

  rts = stdenv.mkDerivation {
    name = "asc-rts";

    src = subpath ./rts;
    nativeBuildInputs = [ nixpkgs.makeWrapper ];

    buildInputs = llvmBuildInputs;

    preBuild = ''
      ${llvmEnv}
      export TOMMATHSRC=${libtommath}
    '';

    installPhase = ''
      mkdir -p $out/rts
      cp as-rts.wasm $out/rts
    '';
  };

  asc-bin = stdenv.mkDerivation {
    name = "asc-bin";

    src = subpath ./src;

    buildInputs = commonBuildInputs;

    buildPhase = ''
      make DUNE_OPTS="--display=short --profile release" asc as-ld
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp --verbose --dereference asc as-ld $out/bin
    '';
  };

  asc = nixpkgs.symlinkJoin {
    name = "asc";
    paths = [ asc-bin rts ];
    buildInputs = [ nixpkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/asc \
        --set-default ASC_RTS "$out/rts/as-rts.wasm"
    '';
  };

  tests = stdenv.mkDerivation {
    name = "tests";
    src = subpath ./test;
    buildInputs =
      [ asc
        didc
        ocaml_wasm
        nixpkgs.wabt
        nixpkgs.bash
        nixpkgs.perl
        nixpkgs.getconf
        nixpkgs.nodejs-10_x
        filecheck
        js-client
      ] ++
      (if test-dvm then [ real-dvm ] else []) ++
      llvmBuildInputs;

    buildPhase = ''
        patchShebangs .
        ${llvmEnv}
        export ASC=asc
        export AS_LD=as-ld
        export DIDC=didc
        export JSCLIENT=${js-client}
        asc --version
      '' +
      (if test-dvm then ''
        make parallel
      '' else ''
        make quick
      '');

    installPhase = ''
      touch $out
    '';
  };

  unit-tests = stdenv.mkDerivation {
    name = "unit-tests";

    src = subpath ./src;

    buildInputs = commonBuildInputs;

    buildPhase = ''
      make DUNE_OPTS="--display=short" unit-tests
    '';

    installPhase = ''
      touch $out
    '';
  };

  as-ide = stdenv.mkDerivation {
    name = "as-ide";

    src = subpath ./src;

    buildInputs = commonBuildInputs;

    buildPhase = ''
      make DUNE_OPTS="--display=short --profile release" as-ide
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp --verbose --dereference as-ide $out/bin
    '';
  };

  samples = stdenv.mkDerivation {
    name = "samples";
    src = subpath ./samples;
    buildInputs =
      [ asc
        didc
        ocaml_wasm
        nixpkgs.wabt
        nixpkgs.bash
        nixpkgs.perl
        filecheck
      ] ++
      (if test-dvm then [ real-dvm ] else []) ++
      llvmBuildInputs;

    buildPhase = ''
        patchShebangs .
        export ASC=asc
        make all
      '';
    installPhase = ''
      touch $out
    '';
  };

  js = asc-bin.overrideAttrs (oldAttrs: {
    name = "asc.js";

    buildInputs = commonBuildInputs ++ [
      nixpkgs.ocamlPackages.js_of_ocaml
      nixpkgs.ocamlPackages.js_of_ocaml-ocamlbuild
      nixpkgs.ocamlPackages.js_of_ocaml-ppx
      nixpkgs.nodejs-10_x
    ];

    buildPhase = ''
      make asc.js
    '';

    installPhase = ''
      mkdir -p $out
      cp -v asc.js $out
      cp -vr ${rts}/rts $out
    '';

    doInstallCheck = true;

    installCheckPhase = ''
      NODE_PATH=$out node --experimental-wasm-mut-global --experimental-wasm-mv ${./test/node-test.js}
    '';

  });

  didc = stdenv.mkDerivation {
    name = "didc";
    src = subpath ./src;
    buildInputs = commonBuildInputs;
    buildPhase = ''
      make DUNE_OPTS="--display=short --profile release" didc
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp --verbose --dereference didc $out/bin
    '';
  };

  wasm = ocaml_wasm;
  dvm = real-dvm;
  filecheck = nixpkgs.linkFarm "FileCheck"
    [ { name = "bin/FileCheck"; path = "${nixpkgs.llvm}/bin/FileCheck";} ];
  wabt = nixpkgs.wabt;


  users-guide = stdenv.mkDerivation {
    name = "users-guide";
    src = subpath ./guide;
    buildInputs =
      with nixpkgs;
      let tex = texlive.combine {
        inherit (texlive) scheme-small xetex newunicodechar;
      }; in
      [ pandoc tex bash ];

    NIX_FONTCONFIG_FILE =
      with nixpkgs;
      nixpkgs.makeFontsConf { fontDirectories = [ gyre-fonts inconsolata unifont lmodern lmmath ]; };

    buildPhase = ''
      patchShebangs .
      make
    '';

    installPhase = ''
      mkdir -p $out
      mv * $out/
      rm $out/Makefile
      mkdir -p $out/nix-support
      echo "report guide $out/guide index.html" >> $out/nix-support/hydra-build-products
    '';
  };

  stdlib = stdenv.mkDerivation {
    name = "stdlib";
    src = subpath ./stdlib;
    buildInputs = with nixpkgs;
      [ bash ];
    buildPhase = ''
      patchShebangs .
    '';
    installPhase = ''
      mkdir -p $out
      tar -rf $out/stdlib.tar $src
      mkdir -p $out/nix-support
      echo "report stdlib $out/stdlib.tar" >> $out/nix-support/hydra-build-products
    '';
    forceShare = ["man"];
  };

  stdlib-doc-live = stdenv.mkDerivation {
    name = "stdlib-doc-live";
    src = subpath ./stdlib;
    buildInputs = with nixpkgs;
      [ pandoc bash python ];
    buildPhase = ''
      patchShebangs .
      make alldoc
    '';
    installPhase = ''
      mkdir -p $out
      mv doc $out/
      mkdir -p $out/nix-support
      echo "report docs $out/doc README.html" >> $out/nix-support/hydra-build-products
    '';
    forceShare = ["man"];
  };

  stdlib-doc = stdenv.mkDerivation {
    name = "stdlib-doc";
    src = subpath ./stdlib;
    buildInputs = with nixpkgs;
      [ pandoc bash python ];
    buildPhase = ''
      patchShebangs .
      make alldoc
    '';
    installPhase = ''
      mkdir -p $out
      tar -rf $out/stdlib-doc.tar doc
      mkdir -p $out/nix-support
      echo "report stdlib-doc $out/stdlib-doc.tar" >> $out/nix-support/hydra-build-products
    '';
    forceShare = ["man"];
  };

  produce-exchange = stdenv.mkDerivation {
    name = "produce-exchange";
    src = subpath ./stdlib;
    buildInputs = [
      asc
    ];

    doCheck = true;
    buildPhase = ''
      make ASC=asc OUTDIR=_out _out/ProduceExchange.wasm
    '';
    checkPhase = ''
      make ASC=asc OUTDIR=_out _out/ProduceExchange.out
    '';
    installPhase = ''
      mkdir -p $out
      cp _out/ProduceExchange.wasm $out
    '';
  };

  all-systems-go = nixpkgs.releaseTools.aggregate {
    name = "all-systems-go";
    constituents = [
      asc
      as-ide
      js
      didc
      tests
      unit-tests
      samples
      rts
      stdlib
      stdlib-doc
      stdlib-doc-live
      produce-exchange
      users-guide
    ];
  };

  shell = if export-shell then nixpkgs.mkShell {
    #
    # Since building asc, and testing it, are two different derivations in we
    # have to create a fake derivation for `nix-shell` that commons up the
    # build dependencies of the two to provide a build environment that offers
    # both.
    #

    buildInputs = nixpkgs.lib.lists.unique (builtins.filter (i: i != asc && i != didc) (
      asc-bin.buildInputs ++
      js.buildInputs ++
      rts.buildInputs ++
      didc.buildInputs ++
      tests.buildInputs ++
      users-guide.buildInputs ++
      [ nixpkgs.ncurses nixpkgs.ocamlPackages.merlin ]
    ));

    shellHook = llvmEnv;
    TOMMATHSRC = libtommath;
    JSCLIENT = js-client;
    NIX_FONTCONFIG_FILE = users-guide.NIX_FONTCONFIG_FILE;
  } else null;

}
