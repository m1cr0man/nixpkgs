{ config, lib, pkgs, options, ... }:
with lib;
let
  cfg = config.security.acme;

  # Used to calculate timer accuracy for coalescing
  numCerts = length (builtins.attrNames cfg.certs);
  _24hSecs = 60 * 60 * 24;

  commonServiceConfig = {
      Type = "oneshot";
      User = "acme";
      Umask = 0027;
      StateDirectoryMode = 750;
      ProtectSystem = "full";
      PrivateTmp = true;

      WorkingDirectory = "/tmp";
  };

  # In order to avoid race conditions creating the CA for selfsigned certs,
  # we have a separate service which will create the necessary files.
  selfsignCAService = {
    description = "Generate self-signed certificate authority";

    path = with pkgs; [ minica ];

    unitConfig = {
      ConditionPathExists = "!/var/lib/acme/.minica/key.pem";
    };

    serviceConfig = commonServiceConfig // {
      StateDirectory = "acme/.minica";

      BindPaths = "/var/lib/acme/.minica:/tmp/ca";
    };

    # Working directory will be /tmp
    script = ''
      minica \
        --ca-key ca/key.pem \
        --ca-cert ca/cert.pem \
        --domains selfsigned.local

      chmod 600 ca/*
    '';
  };

  # Previously, all certs were owned by whatever user was configured in
  # config.security.acme.certs.<cert>.user. Now everything is owned by and
  # run by the acme user.
  userMigrationService = {
    description = "Fix owner group of all ACME certificates";

    # Working directory will be /var/lib/acme
    script = with builtins; concatStringsSep "\n" (mapAttrsToList (cert: data: ''
      chmod -R 750 \
        /var/lib/acme/'${cert}' \
        /var/lib/acme/.lego/'${cert}'
      chown -R acme:${data.group} \
        /var/lib/acme/'${cert}' \
        /var/lib/acme/.lego/'${cert}'
    '') certConfigs);
  };

  certToConfig = cert: data: let
    acmeServer = if data.server != null then data.server else cfg.server;
    useDns = data.dnsProvider != null;
    keyName = builtins.replaceStrings ["*"] ["_"] data.domain;
    destPath = "/var/lib/acme/${cert}";

    # FIXME when mkChangedOptionModule supports submodules, change to that.
    # This is a workaround
    extraDomains = data.extraDomainNames ++ (
      optionals
      (data.extraDomains != "_mkMergedOptionModule")
      (builtins.attrNames data.extraDomains)
    );

    # Create hashes for cert data directories based on configuration
    hashData = with builtins; ''
      ${data.domain} ${data.keyType}
      ${toString cfg.validMinDays} ${concatStringsSep " " extraDomains}
      ${toString acmeServer} ${toString data.dnsProvider}
    '';
    mkHash = with builtins; val: substring 0 20 (hashString "sha256" val);
    certDir = mkHash hashData;
    othersHash = mkHash "${toString acmeServer} ${data.keyType}";
    keyDir = "key-" + othersHash;
    accountDir = "/var/lib/acme/.lego/accounts/" + othersHash;

    protocolOpts = if useDns then (
      [ "--dns" data.dnsProvider ]
      ++ optionals (!data.dnsPropagationCheck) [ "--dns.disable-cp" ]
    ) else (
      [ "--http" "--http.webroot" data.webroot ]
    );

    commonOpts = [
      "--accept-tos" # Checking the option is covered by the assertions
      "--path" "."
      "-d" data.domain
      "--email" data.email
      "--key-type" data.keyType
    ] ++ protocolOpts
      ++ optionals data.ocspMustStaple [ "--must-staple" ]
      ++ optionals (acmeServer != null) [ "--server" acmeServer ]
      ++ concatMap (name: [ "-d" name ]) extraDomains;

    runOpts = escapeShellArgs (commonOpts ++ [ "run" ]);
    renewOpts = escapeShellArgs (
      commonOpts
      ++ [ "renew" "--reuse-key" "--days" (toString cfg.validMinDays) ]
      ++ data.extraLegoRenewFlags
    );

  in {
    inherit accountDir;

    webroot = data.webroot;
    group = data.group;

    renewTimer = {
      description = "Renew ACME Certificate for ${cert}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.renewInterval;
        Unit = "acme-${cert}.service";
        Persistent = "yes";

        # Allow systemd to pick a convenient time within the day
        # to run the check.
        # This allows the coalescing of multiple timer jobs.
        # We divide by the number of certificates so that if you
        # have many certificates, the renewals are distributed over
        # the course of the day to avoid rate limits.
        AccuracySec = "${toString (_24hSecs / numCerts)}s";

        # Skew randomly within the day, per https://letsencrypt.org/docs/integration-guide/.
        RandomizedDelaySec = "24h";
      };
    };

    selfsignService = {
      description = "Generate self-signed certificate for ${cert}";
      after = [ "acme-selfsigned-ca.service" "acme-fixperms.service" ];
      wants = [ "acme-selfsigned-ca.service" "acme-fixperms.service" ];

      path = with pkgs; [ minica ];

      unitConfig = {
        ConditionPathExists = "!/var/lib/acme/${cert}/key.pem";
      };

      serviceConfig = commonServiceConfig // {
        Group = data.group;

        StateDirectory = "acme/${cert}";

        BindPaths = "/var/lib/acme/.minica:/tmp/ca /var/lib/acme/${cert}:/tmp/${data.domain}";
      };

      # Working directory will be /tmp
      # minica will output to a folder sharing the name of the first domain
      # in the list, which will be ${data.domain}
      script = ''
        minica \
          --ca-key ca/key.pem \
          --ca-cert ca/cert.pem \
          --domains '${builtins.concatStringsSep "," ([ data.domain ] ++ extraDomains)}'

        # Create files to match directory layout for real certificates
        cd '${data.domain}'
        cp ../ca/cert.pem chain.pem
        cat chain.pem cert.pem > fullchain.pem
        cat key.pem fullchain.pem > full.pem

        chmod 640 *

        # Group might change between runs, re-apply it
        chown 'acme:${data.group}' *
      '';
    };

    renewService = {
      description = "Renew ACME certificate for ${cert}";
      after = [ "network.target" "network-online.target" "acme-selfsigned-${cert}.service" "acme-fixperms.service" ];
      wants = [ "network-online.target" "acme-selfsigned-${cert}.service" "acme-fixperms.service" ];

      # https://github.com/NixOS/nixpkgs/pull/81371#issuecomment-605526099
      wantedBy = optionals (!config.boot.isContainer) [ "multi-user.target" ];

      path = with pkgs; [ lego coreutils ];

      serviceConfig = commonServiceConfig // {
        Group = data.group;

        # AccountDir dir will be created by tmpfiles to ensure correct permissions
        # And to avoid deletion during systemctl clean
        # acme/.lego/${cert} is listed so that it is deleted during systemctl clean
        StateDirectory = "acme/${cert} acme/.lego/${cert} acme/.lego/${cert}/${certDir} acme/.lego/${cert}/${keyDir}";

        # Needs to be space separated, but can't use a multiline string because that'll include newlines
        BindPaths =
          "${accountDir}:/tmp/accounts " +
          "/var/lib/acme/${cert}:/tmp/out " +
          "/var/lib/acme/.lego/${cert}/${certDir}:/tmp/certificates " +
          "/var/lib/acme/.lego/${cert}/${keyDir}:/tmp/keys";

        # Only try loading the credentialsFile if the dns challenge is enabled
        EnvironmentFile = mkIf useDns data.credentialsFile;
      };

      # Working directory will be /tmp
      script = ''
        set -euo pipefail

        # Safely copy keyDir contents into certificates (it might be empty).
        cp -af keys/. certificates/

        # Check if we can renew
        ls -al certificates accounts
        if [ -e 'certificates/${keyName}.key' -a -e 'certificates/${keyName}.crt' ]; then
          lego ${renewOpts}

        # Otherwise do a full run
        else
          lego ${runOpts}
        fi

        chmod 640 certificates/*
        chmod -R 700 accounts/*

        # Group might change between runs, re-apply it
        chown 'acme:${data.group}' certificates/*

        # Copy the key to keyDir
        cp -pf 'certificates/${keyName}.key' 'keys/'

        # Copy all certs to the "real" certs directory
        CERT='certificates/${keyName}.crt'
        CERT_CHANGED=no
        if [ -e "$CERT" -a "$CERT" -nt out/fullchain.pem ]; then
          CERT_CHANGED=yes
          cp -p 'certificates/${keyName}.crt' out/fullchain.pem
          cp -p 'certificates/${keyName}.key' out/key.pem
          cp -p 'certificates/${keyName}.issuer.crt' out/chain.pem
          ln -sf fullchain.pem cert.pem
          cat out/key.pem out/fullchain.pem > out/full.pem
        fi

        if [ "$CERT_CHANGED" = "yes" ]; then
          cd out
          set +euo pipefail
          ${data.postRun}
        fi
      '';
    };
  };

  certConfigs = mapAttrs certToConfig cfg.certs;

  certOpts = { name, ... }: {
    options = {
      # user option has been removed
      user = mkOption {
        visible = false;
        readOnly = true;
        default = "_mkRemovedOptionModule";
        apply = x: throw ''The option 'security.acme.certs.<cert>.user' can no longer be used since it's been removed.
          Certificate user is now hard coded to the "acme" user. If you would
          like another user to have access, consider adding them to the
          "acme" group or changing security.acme.certs.<name>.group.
        '';
      };

      # allowKeysForGroup option has been removed
      allowKeysForGroup = mkOption {
        visible = false;
        readOnly = true;
        default = "_mkRemovedOptionModule";
        apply = x: throw ''The option 'security.acme.certs.<cert>.allowKeysForGroup' can no longer be used since it's been removed.
          All certs are readable by the configured group. If this is undesired,
          consider changing security.acme.certs.<cert>.group to an unused group.
        '';
      };

      # extraDomains was replaced with extraDomainNames
      extraDomains = mkOption {
        visible = false;
        default = "_mkMergedOptionModule";
      };

      webroot = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/var/lib/acme/acme-challenges";
        description = ''
          Where the webroot of the HTTP vhost is located.
          <filename>.well-known/acme-challenge/</filename> directory
          will be created below the webroot if it doesn't exist.
          <literal>http://example.org/.well-known/acme-challenge/</literal> must also
          be available (notice unencrypted HTTP).
        '';
      };

      server = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          ACME Directory Resource URI. Defaults to Let's Encrypt's
          production endpoint,
          <link xlink:href="https://acme-v02.api.letsencrypt.org/directory"/>, if unset.
        '';
      };

      domain = mkOption {
        type = types.str;
        default = name;
        description = "Domain to fetch certificate for (defaults to the entry name).";
      };

      email = mkOption {
        type = types.nullOr types.str;
        default = cfg.email;
        description = "Contact email address for the CA to be able to reach you.";
      };

      group = mkOption {
        type = types.str;
        default = "acme";
        description = "Group running the ACME client.";
      };

      postRun = mkOption {
        type = types.lines;
        default = "";
        example = "systemctl reload nginx.service";
        description = ''
          Commands to run after new certificates go live. Typically
          the web server and other servers using certificates need to
          be reloaded.

          Executed in the same directory with the new certificate.
        '';
      };

      directory = mkOption {
        type = types.str;
        readOnly = true;
        default = "/var/lib/acme/${name}";
        description = "Directory where certificate and other state is stored.";
      };

      extraDomainNames = mkOption {
        type = types.listOf types.str;
        default = [];
        example = literalExample ''
          [
            "example.org"
            "mydomain.org"
          ]
        '';
        description = ''
          A list of extra domain names, which are included in the one certificate to be issued.
        '';
      };

      keyType = mkOption {
        type = types.str;
        default = "ec256";
        description = ''
          Key type to use for private keys.
          For an up to date list of supported values check the --key-type option
          at <link xlink:href="https://go-acme.github.io/lego/usage/cli/#usage"/>.
        '';
      };

      dnsProvider = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "route53";
        description = ''
          DNS Challenge provider. For a list of supported providers, see the "code"
          field of the DNS providers listed at <link xlink:href="https://go-acme.github.io/lego/dns/"/>.
        '';
      };

      credentialsFile = mkOption {
        type = types.path;
        description = ''
          Path to an EnvironmentFile for the cert's service containing any required and
          optional environment variables for your selected dnsProvider.
          To find out what values you need to set, consult the documentation at
          <link xlink:href="https://go-acme.github.io/lego/dns/"/> for the corresponding dnsProvider.
        '';
        example = "/var/src/secrets/example.org-route53-api-token";
      };

      dnsPropagationCheck = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Toggles lego DNS propagation check, which is used alongside DNS-01
          challenge to ensure the DNS entries required are available.
        '';
      };

      ocspMustStaple = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Turns on the OCSP Must-Staple TLS extension.
          Make sure you know what you're doing! See:
          <itemizedlist>
            <listitem><para><link xlink:href="https://blog.apnic.net/2019/01/15/is-the-web-ready-for-ocsp-must-staple/" /></para></listitem>
            <listitem><para><link xlink:href="https://blog.hboeck.de/archives/886-The-Problem-with-OCSP-Stapling-and-Must-Staple-and-why-Certificate-Revocation-is-still-broken.html" /></para></listitem>
          </itemizedlist>
        '';
      };

      extraLegoRenewFlags = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Additional flags to pass to lego renew.
        '';
      };
    };
  };

in {

  options = {
    security.acme = {

      validMinDays = mkOption {
        type = types.int;
        default = 30;
        description = "Minimum remaining validity before renewal in days.";
      };

      email = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Contact email address for the CA to be able to reach you.";
      };

      renewInterval = mkOption {
        type = types.str;
        default = "daily";
        description = ''
          Systemd calendar expression when to check for renewal. See
          <citerefentry><refentrytitle>systemd.time</refentrytitle>
          <manvolnum>7</manvolnum></citerefentry>.
        '';
      };

      server = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          ACME Directory Resource URI. Defaults to Let's Encrypt's
          production endpoint,
          <link xlink:href="https://acme-v02.api.letsencrypt.org/directory"/>, if unset.
        '';
      };

      preliminarySelfsigned = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether a preliminary self-signed certificate should be generated before
          doing ACME requests. This can be useful when certificates are required in
          a webserver, but ACME needs the webserver to make its requests.

          With preliminary self-signed certificate the webserver can be started and
          can later reload the correct ACME certificates.
        '';
      };

      acceptTerms = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Accept the CA's terms of service. The default provider is Let's Encrypt,
          you can find their ToS at <link xlink:href="https://letsencrypt.org/repository/"/>.
        '';
      };

      certs = mkOption {
        default = { };
        type = with types; attrsOf (submodule certOpts);
        description = ''
          Attribute set of certificates to get signed and renewed. Creates
          <literal>acme-''${cert}.{service,timer}</literal> systemd units for
          each certificate defined here. Other services can add dependencies
          to those units if they rely on the certificates being present,
          or trigger restarts of the service if certificates get renewed.
        '';
        example = literalExample ''
          {
            "example.com" = {
              webroot = "/var/www/challenges/";
              email = "foo@example.com";
              extraDomainNames = [ "www.example.com" "foo.example.com" ];
            };
            "bar.example.com" = {
              webroot = "/var/www/challenges/";
              email = "bar@example.com";
            };
          }
        '';
      };
    };
  };

  imports = [
    (mkRemovedOptionModule [ "security" "acme" "production" ] ''
      Use security.acme.server to define your staging ACME server URL instead.

      To use the let's encrypt staging server, use security.acme.server =
      "https://acme-staging-v02.api.letsencrypt.org/directory".
    ''
    )
    (mkRemovedOptionModule [ "security" "acme" "directory" ] "ACME Directory is now hardcoded to /var/lib/acme and its permisisons are managed by systemd. See https://github.com/NixOS/nixpkgs/issues/53852 for more info.")
    (mkRemovedOptionModule [ "security" "acme" "preDelay" ] "This option has been removed. If you want to make sure that something executes before certificates are provisioned, add a RequiredBy=acme-\${cert}.service to the service you want to execute before the cert renewal")
    (mkRemovedOptionModule [ "security" "acme" "activationDelay" ] "This option has been removed. If you want to make sure that something executes before certificates are provisioned, add a RequiredBy=acme-\${cert}.service to the service you want to execute before the cert renewal")
    (mkChangedOptionModule [ "security" "acme" "validMin" ] [ "security" "acme" "validMinDays" ] (config: config.security.acme.validMin / (24 * 3600)))

    # ({ config, ... }: {
    #   # Map extraDomains to extraDomainNames
    #   config.security.acme.certs = mapAttrs (cert: data: optionalAttrs (data.extraDomains != "_mkMergedOptionModule") (mkMerge {
    #     extraDomainNames = attrValues data.extraDomains;
    #   })) config.security.acme.certs;
    # })
  ];

  config = mkMerge [
    (mkIf (cfg.certs != { }) {

      # FIXME Most of these custom warnings and filters for security.acme.certs.* are required
      # because using mkRemovedOptionModule/mkChangedOptionModule with attrsets isn't possible.
      warnings = filter (w: w != "") (mapAttrsToList (cert: data: if data.extraDomains != "_mkMergedOptionModule" then ''
        The option definition `security.acme.certs.${cert}.extraDomains` has changed
        to `security.acme.certs.${cert}.extraDomainNames` and is now a list of strings.
        Setting a custom webroot for extra domains is not possible, instead use separate certs.
      '' else "") cfg.certs);

      assertions = let
        certs = attrValues cfg.certs;
      in [
        {
          assertion = cfg.email != null || all (certOpts: certOpts.email != null) certs;
          message = ''
            You must define `security.acme.certs.<name>.email` or
            `security.acme.email` to register with the CA. Note that using
            many different addresses for certs may trigger account rate limits.
          '';
        }
        {
          assertion = cfg.acceptTerms;
          message = ''
            You must accept the CA's terms of service before using
            the ACME module by setting `security.acme.acceptTerms`
            to `true`. For Let's Encrypt's ToS see https://letsencrypt.org/repository/
          '';
        }
      ] ++ (builtins.concatLists (mapAttrsToList (cert: data: [
        # FIXME how do you do assertions like this on a submodule?
        # {
        #   assertion = !options.security.acme.certs."${cert}".user.isDefined;
        #   message = ''
        #     The option definition `security.acme.certs.${cert}.user' no longer has any effect; Please remove it.
        #     Certificate user is now hard coded to the "acme" user. If you would
        #     like another user to have access, consider adding them to the
        #     "acme" group or changing security.acme.certs.${cert}.group.
        #   '';
        # }
        # {
        #   assertion = !options.security.acme.certs."${cert}".allowKeysForGroup.isDefined;
        #   message = ''
        #     The option definition `security.acme.certs.${cert}.allowKeysForGroup' no longer has any effect; Please remove it.
        #     All certs are readable by the configured group. If this is undesired,
        #     consider changing security.acme.certs.${cert}.group to an unused group.
        #   '';
        # }
        # {
        #   assertion = !options.security.acme.certs."${cert}".directory.isDefined;
        #   message = ''
        #     The option definition `security.acme.certs.${cert}.directory' no longer has any effect; Please remove it.
        #     Certificate directory is now hard coded to /var/lib/acme/${cert}.
        #     Consider adding a custom script with security.acme.certs.${cert}.postRun
        #     to symlink the files wherever you need them.
        #   '';
        # }
        {
          assertion = data.dnsProvider == null || data.webroot == null;
          message = ''
            Options `security.acme.certs.${cert}.dnsProvider` and
            `security.acme.certs.${cert}.webroot` are mutually exclusive.
          '';
        }
      ]) cfg.certs));

      users.users.acme = {
        uid = config.ids.uids.acme;
        home = "/var/lib/acme";
        group = "acme";
      };

      users.groups.acme = {
        gid = config.ids.gids.acme;
      };

      systemd.services = {
        "acme-fixperms" = userMigrationService;
      } // (mapAttrs' (cert: conf: nameValuePair "acme-${cert}" conf.renewService) certConfigs)
        // (optionalAttrs (cfg.preliminarySelfsigned) ({
        "acme-selfsigned-ca" = selfsignCAService;
      } // (mapAttrs' (cert: conf: nameValuePair "acme-selfsigned-${cert}" conf.selfsignService) certConfigs)));

      systemd.timers = mapAttrs' (cert: conf: nameValuePair "acme-${cert}" conf.renewTimer) certConfigs;

      # .lego and .lego/accounts specified to fix any incorrect permissions
      systemd.tmpfiles.rules = [
        "d /var/lib/acme/.lego - acme acme"
        "d /var/lib/acme/.lego/accounts - acme acme"
      ] ++ (unique (concatMap (conf: [
          "d ${conf.accountDir} - acme acme"
        ] ++ (optional (conf.webroot != null) "d ${conf.webroot}/.well-known/acme-challenge - acme ${conf.group}")
      ) (attrValues certConfigs)));

      systemd.targets.acme-selfsigned-certificates = mkIf cfg.preliminarySelfsigned {};
      systemd.targets.acme-certificates = {};
    })
  ];

  meta = {
    maintainers = lib.teams.acme.members;
    doc = ./acme.xml;
  };
}
