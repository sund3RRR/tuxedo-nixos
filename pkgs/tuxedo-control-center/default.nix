{
  lib,
  pkgs,
  stdenv,
  nodePackages,
  python3,
  udev,
  makeWrapper,
  nodejs,
  electron,
  fetchFromGitHub,
  gnugrep,
  gawk,
  xorg,
  procps,
  which,
}:

let
  version = "2.1.22";
  inherit nodejs;

  baseNodePackages = (
    import ./node-composition.nix {
      inherit pkgs nodejs;
      inherit (stdenv.hostPlatform) system;
    }
  );

  nodePackages' = baseNodePackages.package.override {
    src = fetchFromGitHub {
      owner = "tuxedocomputers";
      repo = "tuxedo-control-center";
      rev = "v${version}";
      hash = "sha256-W4890yTlMJaaC4g4Dmbj6mQHJTJLlB9z9OTxYj4TnhY=";
    };

    preRebuild = ''
      # the shebang of this file does not work as is in nix;
      # usually this is taken care of with patch-shebangs.sh,
      # but that only handles files marked as executable.
      # thus mark the file as executable before the hook runs.
      chmod +x ./node_modules/electron-builder/out/cli/cli.js
      # and since this runs *after* patch-shebangs ran,
      # manually execute patch-shebangs for this specific file.
      patchShebangs ./node_modules/electron-builder/out/cli/cli.js
    '';

    buildInputs = [
      udev
    ];

    # Electron tries to download itself if this isn't set. We don't
    # like that in nix so let's prevent it.
    #
    # This means we have to provide our own electron binaries when
    # wrapping this program.
    ELECTRON_SKIP_BINARY_DOWNLOAD = 1;

    # Angular prompts for analytics, which in turn fails the build.
    #
    # We can disable analytics using false or empty string
    # (See https://github.com/angular/angular-cli/blob/1a39c5202a6fe159f8d7db85a1c186176240e437/packages/angular/cli/models/analytics.ts#L506)
    NG_CLI_ANALYTICS = "false";
  };

in

stdenv.mkDerivation {
  pname = "tuxedo-control-center";
  inherit version;

  src = "${nodePackages'}/lib/node_modules/tuxedo-control-center/";

  nativeBuildInputs = [
    makeWrapper
  ];

  buildInputs = [
    nodejs
    udev

    # For node-gyp
    python3
    nodePackages.node-gyp
  ];

  postPatch = ''
    substituteInPlace src/common/classes/TccPaths.ts \
      --replace "/etc/tcc" "/var/lib/tcc" \
      --replace "/opt/tuxedo-control-center/resources/dist/tuxedo-control-center/data/service/tccd" "$out/bin/tccd" \
      --replace "/opt/tuxedo-control-center/resources/dist/tuxedo-control-center/data/camera/cameractrls.py" \
        "$out/libexec/cameractrls.py" \
      --replace "/opt/tuxedo-control-center/resources/dist/tuxedo-control-center/data/camera/v4l2_kernel_names.json" \
        "$out/share/tcc/v4l2_kernel_names.json"

    substituteInPlace src/e-app/main.ts \
      --replace "../../data/dist-data/tuxedo-control-center_256.png" "../../share/icons/hicolor/scalable/apps/tuxedo-control-center_256.png" \
      --replace "appPath, '../../data/dist-data'" "'$out/share/tcc'"

    substituteInPlace src/dist-data/tccd-sleep.service \
      --replace "/bin/bash -c " ""

    substituteInPlace src/dist-data/tccd.service \
      --replace "/opt/tuxedo-control-center/resources/dist/tuxedo-control-center/data/service/tccd" "$out/bin/tccd"

    substituteInPlace src/dist-data/tuxedo-control-center-tray.desktop \
      --replace "/opt/tuxedo-control-center/tuxedo-control-center" "tuxedo-control-center" \
      --replace "Icon=tuxedo-control-center" "Icon=tuxedo-control-center_256"

    substituteInPlace src/dist-data/tuxedo-control-center.desktop \
      --replace "/opt/tuxedo-control-center/tuxedo-control-center" "$out/bin/tuxedo-control-center" \
      --replace "/opt/tuxedo-control-center/resources/dist/tuxedo-control-center/data/dist-data/tuxedo-control-center_256.svg" \
        "$out/share/icons/hicolor/scalable/apps/tuxedo-control-center_256.svg"

    substituteInPlace src/udev/99-webcam.rules \
      --replace "/usr/bin/python3" "${python3}/bin/python3" \
      --replace "/opt/tuxedo-control-center/resources/dist/tuxedo-control-center/data/camera/cameractrls.py" "$out/libexec/cameractrls.py" \
      --replace "/etc/tcc/webcam" "/var/lib/tcc/webcam" \
      --replace "/opt/tuxedo-control-center/resources/dist/tuxedo-control-center/data/camera/v4l2_kernel_names.json" "$out/share/tcc/v4l2_kernel_names.json"
  '';

  buildPhase = ''
    runHook preBuild

    # We already have `node_modules` in the current directory but we
    # need it's binaries on `PATH` so we can use them!
    export PATH="./node_modules/.bin:$PATH"
    # Prevent npm from checking for updates
    export NO_UPDATE_NOTIFIER=true

    # The order of `npm` commands matches what `npm run build-prod` does but we split
    # it out so we can customise the native builds in `npm run build-service`.
    npm run clean
    npm run build-electron

    # We don't use `npm run build-service` here because it uses `pkg` which packages
    # node binaries in a way unsuitable for nix. Instead we're doing it ourself.
    tsc -p ./src/service-app
    cp ./src/package.json ./dist/tuxedo-control-center/service-app/package.json

    # We need to tell npm where to find node or `node-gyp` will try to download it.
    # This also _needs_ to be lowercase or `npm` won't detect it
    export npm_config_nodedir=${nodejs}
    ${nodePackages.node-gyp}/bin/node-gyp configure && ${nodePackages.node-gyp}/bin/node-gyp rebuild # Builds to ./build/Release/TuxedoIOAPI.node

    npm run build-ng-prod

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -R ./dist/tuxedo-control-center/* $out

    ln -s $src/node_modules $out/node_modules

    mkdir -p $out/service-app/native-lib
    cp ./build/Release/TuxedoIOAPI.node $out/service-app/native-lib/TuxedoIOAPI.node

    mkdir -p $out/share/applications \
      $out/libexec \
      $out/share/tcc \
      $out/share/polkit-1/actions \
      $out/share/metainfo \
      $out/lib/systemd/system \
      $out/etc/dbus-1/system.d \
      $out/etc/udev/rules.d
    cp src/dist-data/tuxedo-control-center.desktop $out/share/applications/
    cp src/cameractrls/cameractrls.py $out/libexec/
    cp src/cameractrls/v4l2_kernel_names.json $out/share/tcc/
    cp src/dist-data/tuxedo-control-center-tray.desktop $out/share/tcc/
    cp src/dist-data/com.tuxedocomputers.tccd.policy $out/share/polkit-1/actions/
    cp src/dist-data/com.tuxedocomputers.tomte.policy $out/share/polkit-1/actions/
    cp src/dist-data/com.tuxedocomputers.tcc.metainfo.xml $out/share/metainfo/
    cp src/dist-data/tccd-sleep.service $out/lib/systemd/system/
    cp src/dist-data/tccd.service $out/lib/systemd/system/
    cp src/dist-data/com.tuxedocomputers.tccd.conf $out/etc/dbus-1/system.d/
    cp src/udev/99-webcam.rules $out/etc/udev/rules.d/

    mkdir -p $out/share/icons/hicolor/scalable/apps/
    cp src/dist-data/tuxedo-control-center_256.svg $out/share/icons/hicolor/scalable/apps/
    cp src/dist-data/tuxedo-control-center_256.png $out/share/icons/hicolor/scalable/apps/

    runHook postInstall
  '';

  postFixup = ''
    makeWrapper ${nodejs}/bin/node $out/bin/tccd \
      --add-flags "$out/service-app/service-app/main.js" \
      --prefix PATH : "${
        lib.makeBinPath [
          gnugrep
          gawk
          xorg.xrandr
          procps
          which
        ]
      }" \
      --prefix NODE_PATH : "$out/node_modules"

    makeWrapper ${electron}/bin/electron $out/bin/tuxedo-control-center \
      --add-flags "$out/e-app/e-app/main.js" \
      --add-flags "--no-tccd-version-check" \
      --prefix PATH : "${lib.makeBinPath [ python3 ]}" \
      --prefix NODE_PATH : "$out/node_modules"
  '';

  meta = with lib; {
    description = "Fan and power management GUI for TUXEDO laptops";
    homepage = "https://github.com/tuxedocomputers/tuxedo-control-center/";
    license = licenses.gpl3Plus;
    mainProgram = "tuxedo-control-center";
    maintainers = [ maintainers.sund3RRR ];
    platforms = [ "x86_64-linux" ];
  };
}
