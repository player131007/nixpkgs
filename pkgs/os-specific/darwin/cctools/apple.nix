{ lib, stdenv, fetchurl, symlinkJoin, xcbuildHook, tcsh, libobjc, libtapi, libunwind, llvm, memstreamHook, xar }:

let

cctools = stdenv.mkDerivation rec {
  pname = "cctools";
  version = "973.0.1";

  src = fetchurl {
    url = "https://opensource.apple.com/tarballs/cctools/cctools-${version}.tar.gz";
    hash = "sha256-r/6tsyyfi3R/0cLl+lN/B9ZaOaVF+Z7vJ6xj4LzSgiQ=";
  };

  patches = [
    ./cctools-add-missing-vtool-libstuff-dep.patch
  ];

  postPatch = ''
    for file in libstuff/writeout.c misc/libtool.c misc/lipo.c; do
      substituteInPlace "$file" \
        --replace '__builtin_available(macOS 10.12, *)' '0'
    done
    substituteInPlace libmacho/swap.c \
      --replace '#ifndef RLD' '#if 1'
  '';

  nativeBuildInputs = [ xcbuildHook memstreamHook ];
  buildInputs = [ libobjc llvm ];

  xcbuildFlags = [
    "MACOSX_DEPLOYMENT_TARGET=10.12"
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    Products/Release/libstuff_test
    rm Products/Release/libstuff_test

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    rm -rf "$out/usr"
    mkdir -p "$out/bin"
    find Products/Release -maxdepth 1 -type f -perm 755 -exec cp {} "$out/bin/" \;
    cp -r include "$out/"

    ln -s ./nm-classic "$out"/bin/nm
    ln -s ./otool-classic "$out"/bin/otool

    runHook postInstall
  '';
};

ld64 = stdenv.mkDerivation rec {
  pname = "ld64";
  version = "609";

  src = fetchurl {
    url = "https://opensource.apple.com/tarballs/ld64/ld64-${version}.tar.gz";
    hash = "sha256-SqQ7SqmK+uOPijzxOTqtkEu3qYmcth6H7rrQ03R1Q+4=";
  };

  postPatch = ''
    substituteInPlace ld64.xcodeproj/project.pbxproj \
      --replace "/bin/csh" "${tcsh}/bin/tcsh" \
      --replace 'F9E8D4BE07FCAF2A00FD5801 /* PBXBuildRule */,' "" \
      --replace 'F9E8D4BD07FCAF2000FD5801 /* PBXBuildRule */,' ""

    sed -i src/ld/Options.cpp -e '1iconst char ldVersionString[] = "${version}";'
  '';

  nativeBuildInputs = [ xcbuildHook ];
  buildInputs = [
    libtapi
    libunwind
    llvm
    xar
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    find Products/Release-assert -maxdepth 1 -type f -perm 755 -exec cp {} "$out/bin/" \;

    runHook postInstall
  '';
};

in

symlinkJoin rec {
  name = "cctools-${version}";
  version = "${cctools.version}-${ld64.version}";

  paths = [
    cctools
    ld64
  ];

  # workaround for the fetch-tarballs script
  passthru = {
    inherit (cctools) src;
    ld64_src = ld64.src;
  };

  meta = with lib; {
    description = "MacOS Compiler Tools";
    homepage = "http://www.opensource.apple.com/source/cctools/";
    license = licenses.apsl20;
    platforms = platforms.darwin;
  };
}
