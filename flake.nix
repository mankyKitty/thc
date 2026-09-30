{
  description = "THC development shell (toolchain pinned per README.md)";

  inputs = {
    # flake.lock pins the revision; it must carry the exact versions below.
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # GraalVM Community 25.3.4.1 / JDK 25; its root is a valid JAVA_HOME.
        graalvm = pkgs.graalvmPackages.graalvm-ce;

        # GHC 9.14.1; ships ghc-pkg and runghc.
        ghcUpstream = pkgs.haskell.compiler.ghc9141;

        # macOS: ghc-internal registers Apple libiconv's include/, which does
        # not exist (headers live in the SDK), and `thc run` rejects missing
        # include dirs. Point it at a dir holding the SDK's iconv.h instead.
        # Not libiconvReal: GNU iconv.h renames iconv_open to libiconv_open,
        # which Apple's dylib lacks.
        iconvInclude = pkgs.runCommand "apple-sdk-iconv-include" { } ''
          mkdir -p $out/include
          ln -s ${pkgs.apple-sdk.sdkroot}/usr/include/iconv.h $out/include/
        '';

        # Thin re-wrap of upstream GHC; no rebuild. Executables and libraries
        # are symlinked; only the wrapper scripts and package db are copied.
        # - bin/ entries are real files, not symlinks: the driver records native
        #   receipts under canonicalizePath(ghc) but checks them against the
        #   PATH-resolved ghc, so a bin/ghc -> ghc-9.14.1 link never matches.
        # - macOS: package db re-registered with iconvInclude (above).
        ghc = pkgs.runCommand "ghc-${ghcUpstream.version}-thc" { } ''
          top=lib/ghc-${ghcUpstream.version}
          lib=$top/lib
          mkdir -p $out/$lib $out/bin
          for f in ${ghcUpstream}/*; do
            case ''${f##*/} in bin|lib) ;; *) ln -s $f $out/ ;; esac
          done
          ln -s ${ghcUpstream}/$top/bin $out/$top/
          for f in ${ghcUpstream}/$lib/*; do
            [ ''${f##*/} = package.conf.d ] || ln -s $f $out/$lib/
          done
          cp -r ${ghcUpstream}/$lib/package.conf.d $out/$lib/
          chmod -R u+w $out/$lib/package.conf.d
          ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            sed -i 's|${pkgs.libiconv}/include|${iconvInclude}/include|' $out/$lib/package.conf.d/*.conf
          ''}
          ${ghcUpstream}/bin/ghc-pkg --global-package-db $out/$lib/package.conf.d recache
          # Same wrapper scripts (resolved through symlinks); only libdir moves.
          for f in ${ghcUpstream}/bin/*; do
            sed 's|^libdir=.*|libdir="'$out/$lib'"|' $f > $out/bin/''${f##*/}
            chmod +x $out/bin/''${f##*/}
          done
        '';
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            ghc
            pkgs.cabal-install # 3.16.x
            graalvm
            pkgs.python3 # >= 3.12
            # Gradle's git apply, submodules; macOS /usr/bin/git is an xcrun
            # shim that fails under Nix's SDK.
            pkgs.git
            pkgs.pandoc # make docs
            pkgs.hlint # make lint-haskell (CI pins 3.10)
            # LLVM 18 as in CI: driver's C-to-bitcode path (clang, llvm-link,
            # opt, llvm-nm, llvm-objcopy) and GHC's LLVM backend (llc, opt).
            # macOS needs it too: Xcode's /usr/bin shims fail under Nix's SDK.
            # macOS: the default clang 18 wrapper's compiler-rt fails to build;
            # bitcode emission doesn't need compiler-rt.
            (
              if pkgs.stdenv.hostPlatform.isDarwin then
                pkgs.llvmPackages_18.clangNoCompilerRt
              else
                pkgs.llvmPackages_18.clang
            )
            pkgs.llvmPackages_18.llvm
          ]
          # Linux: checked GMP limb provider (clang -lgmp).
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.gmp ];

          # make check-java and Gradle read JAVA_HOME.
          JAVA_HOME = graalvm;

          # Warn if a nixpkgs bump drifts off the pinned toolchain.
          shellHook = ''
            case "$(cabal --numeric-version)" in 3.16.*) ;; *) echo "warning: expected cabal 3.16" >&2 ;; esac
            grep -q 'GRAALVM_VERSION="25.3.4.1"' "$JAVA_HOME/release" || echo "warning: expected GraalVM 25.3.4.1" >&2
            # Submodules are not managed by Nix.
            git submodule status 2>/dev/null | grep -q '^-' \
              && echo "note: run: git -c core.autocrlf=false submodule update --init --depth 1" >&2
            true
          '';
        };
      }
    );
}
