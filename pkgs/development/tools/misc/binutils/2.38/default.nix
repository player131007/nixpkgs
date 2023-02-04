let
  execFormatIsELF = platform: platform.parsed.kernel.execFormat.name == "elf";
in

{ stdenv
, autoreconfHook
, autoconf269, automake, libtool
, bison
, buildPackages
, fetchFromGitHub
, fetchurl
, flex
, gettext
, lib
, noSysDirs
, perl
, substitute
, texinfo
, zlib

, enableGold ? execFormatIsELF stdenv.targetPlatform
, enableShared ? !stdenv.hostPlatform.isStatic
  # WARN: Enabling all targets increases output size to a multiple.
, withAllTargets ? false
}:

# WARN: configure silently disables ld.gold if it's unsupported, so we need to
# make sure that intent matches result ourselves.
assert enableGold -> execFormatIsELF stdenv.targetPlatform;


let
  inherit (stdenv) buildPlatform hostPlatform targetPlatform;

  version = "2.38";

  srcs = {
    normal = fetchurl {
      url = "mirror://gnu/binutils/binutils-${version}.tar.bz2";
      sha256 = "sha256-Bw7HHPB3pqWOC5WfBaCaNQFTeMLYpR6Q866r/jBZDvg=";
    };
    vc4-none = fetchFromGitHub {
      owner = "itszor";
      repo = "binutils-vc4";
      rev = "708acc851880dbeda1dd18aca4fd0a95b2573b36";
      sha256 = "1kdrz6fki55lm15rwwamn74fnqpy0zlafsida2zymk76n3656c63";
    };
  };

  #INFO: The targetPrefix prepended to binary names to allow multiple binuntils
  # on the PATH to both be usable.
  targetPrefix = lib.optionalString (targetPlatform != hostPlatform) "${targetPlatform.config}-";
in

stdenv.mkDerivation {
  pname = targetPrefix + "binutils";
  inherit version;

  # HACK: Ensure that we preserve source from bootstrap binutils to not rebuild LLVM
  src = stdenv.__bootPackages.binutils-unwrapped_2_38.src
    or srcs.${targetPlatform.system}
    or srcs.normal;

  # WARN: this package is used for bootstrapping fetchurl, and thus cannot use
  # fetchpatch! All mutable patches (generated by GitHub or cgit) that are
  # needed here should be included directly in Nixpkgs as files.
  patches = [
    # Make binutils output deterministic by default.
    ./deterministic.patch


    # Breaks nm BSD flag detection
    ./0001-Revert-libtool.m4-fix-nm-BSD-flag-detection.patch

    # Required for newer macos versions
    ./0001-libtool.m4-update-macos-version-detection-block.patch

    # For some reason bfd ld doesn't search DT_RPATH when cross-compiling. It's
    # not clear why this behavior was decided upon but it has the unfortunate
    # consequence that the linker will fail to find transitive dependencies of
    # shared objects when cross-compiling. Consequently, we are forced to
    # override this behavior, forcing ld to search DT_RPATH even when
    # cross-compiling.
    ./always-search-rpath.patch

    # Fixed in 2.39
    # https://sourceware.org/bugzilla/show_bug.cgi?id=28885
    # https://sourceware.org/git/?p=binutils-gdb.git;a=patch;h=99852365513266afdd793289813e8e565186c9e6
    # https://github.com/NixOS/nixpkgs/issues/170946
    ./deterministic-temp-prefixes.patch
  ]
  ++ lib.optional targetPlatform.isiOS ./support-ios.patch
  ++ lib.optional stdenv.targetPlatform.isWindows ./windres-locate-gcc.patch
  ++ lib.optional stdenv.targetPlatform.isMips64n64
     # this patch is from debian:
     # https://sources.debian.org/data/main/b/binutils/2.38-3/debian/patches/mips64-default-n64.diff
     (if stdenv.targetPlatform.isMusl
      then substitute { src = ./mips64-default-n64.patch; replacements = [ "--replace" "gnuabi64" "muslabi64" ]; }
      else ./mips64-default-n64.patch)
  # On PowerPC, when generating assembly code, GCC generates a `.machine`
  # custom instruction which instructs the assembler to generate code for this
  # machine. However, some GCC versions generate the wrong one, or make it
  # too strict, which leads to some confusing "unrecognized opcode: wrtee"
  # or "unrecognized opcode: eieio" errors.
  #
  # To remove when binutils 2.39 is released.
  #
  # Upstream commit:
  # https://sourceware.org/git/?p=binutils-gdb.git;a=commit;h=cebc89b9328eab994f6b0314c263f94e7949a553
  ++ lib.optional stdenv.targetPlatform.isPower ./ppc-make-machine-less-strict.patch
  ;

  outputs = [ "out" "info" "man" ];

  strictDeps = true;
  depsBuildBuild = [ buildPackages.stdenv.cc ];
  nativeBuildInputs = [
    bison
    perl
    texinfo
  ]
  ++ lib.optionals targetPlatform.isiOS [ autoreconfHook ]
  ++ lib.optionals buildPlatform.isDarwin [ autoconf269 automake gettext libtool ]
  ++ lib.optionals targetPlatform.isVc4 [ flex ]
  ;

  buildInputs = [ zlib gettext ];

  inherit noSysDirs;

  preConfigure = (lib.optionalString buildPlatform.isDarwin ''
    for i in */configure.ac; do
      pushd "$(dirname "$i")"
      echo "Running autoreconf in $PWD"
      # autoreconf doesn't work, don't know why
      # autoreconf ''${autoreconfFlags:---install --force --verbose}
      autoconf
      popd
    done
  '') + ''
    # Clear the default library search path.
    if test "$noSysDirs" = "1"; then
        echo 'NATIVE_LIB_DIRS=' >> ld/configure.tgt
    fi

    # Use symlinks instead of hard links to save space ("strip" in the
    # fixup phase strips each hard link separately).
    for i in binutils/Makefile.in gas/Makefile.in ld/Makefile.in gold/Makefile.in; do
        sed -i "$i" -e 's|ln |ln -s |'
    done
  '';

  # As binutils takes part in the stdenv building, we don't want references
  # to the bootstrap-tools libgcc (as uses to happen on arm/mips)
  NIX_CFLAGS_COMPILE =
    if hostPlatform.isDarwin
    then "-Wno-string-plus-int -Wno-deprecated-declarations"
    else "-static-libgcc";

  hardeningDisable = [ "format" "pie" ];

  configurePlatforms = [ "build" "host" "target" ];

  configureFlags = [
    "--enable-64-bit-bfd"
    "--with-system-zlib"

    "--enable-deterministic-archives"
    "--disable-werror"
    "--enable-fix-loongson2f-nop"

    # Turn on --enable-new-dtags by default to make the linker set
    # RUNPATH instead of RPATH on binaries.  This is important because
    # RUNPATH can be overridden using LD_LIBRARY_PATH at runtime.
    "--enable-new-dtags"

    # force target prefix. Some versions of binutils will make it empty if
    # `--host` and `--target` are too close, even if Nixpkgs thinks the
    # platforms are different (e.g. because not all the info makes the
    # `config`). Other versions of binutils will always prefix if `--target` is
    # passed, even if `--host` and `--target` are the same. The easiest thing
    # for us to do is not leave it to chance, and force the program prefix to be
    # what we want it to be.
    "--program-prefix=${targetPrefix}"
  ]
  ++ lib.optionals withAllTargets [ "--enable-targets=all" ]
  ++ lib.optionals enableGold [ "--enable-gold" "--enable-plugins" ]
  ++ (if enableShared
      then [ "--enable-shared" "--disable-static" ]
      else [ "--disable-shared" "--enable-static" ])
  ;

  # Fails
  doCheck = false;

  # Remove on next bump. It's a vestige of past conditional. Stays here to avoid
  # mass rebuild.
  postFixup = "";

  # Break dependency on pkgsBuildBuild.gcc when building a cross-binutils
  stripDebugList = if stdenv.hostPlatform != stdenv.targetPlatform then "bin lib ${stdenv.hostPlatform.config}" else null;

  # INFO: Otherwise it fails with:
  # `./sanity.sh: line 36: $out/bin/size: not found`
  doInstallCheck = (buildPlatform == hostPlatform) && (hostPlatform == targetPlatform);

  enableParallelBuilding = true;

  passthru = {
    inherit targetPrefix;
    hasGold = enableGold;
    isGNU = true;
  };

  meta = with lib; {
    description = "Tools for manipulating binaries (linker, assembler, etc.)";
    longDescription = ''
      The GNU Binutils are a collection of binary tools.  The main
      ones are `ld' (the GNU linker) and `as' (the GNU assembler).
      They also include the BFD (Binary File Descriptor) library,
      `gprof', `nm', `strip', etc.
    '';
    homepage = "https://www.gnu.org/software/binutils/";
    license = licenses.gpl3Plus;
    maintainers = with maintainers; [ ericson2314 lovesegfault ];
    platforms = platforms.unix;

    # INFO: Give binutils a lower priority than gcc-wrapper to prevent a
    # collision due to the ld/as wrappers/symlinks in the latter.
    priority = 10;
  };
}
