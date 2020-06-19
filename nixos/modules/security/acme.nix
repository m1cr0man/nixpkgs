{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.security.acme;

  # Used to calculate timer accuracy for coalescing
  numCerts = length (attrNames cfg.certs);
  _24hSecs = 60 * 60 * 24;

  certToConfig = cert: data: let
    serviceName = "acme-${cert}";
    acmeServer = if data.server then data.server else cfg.server;
    useDns = data.dnsProvider != null;
    keyName = builtins.replaceStrings ["*"] ["_"] data.domain;
    destPath = "/var/lib/acme/${cert}";

    # Create hashes for directories for cert data based on configuration
    mkHash = with builtins; data: substring 0 20 (hashString "sha256" data);
    hashData = with data; "${acmeServer} ${keyType} ${dnsProvider} ${validMinDays} ${extraDomains} ${domain}";
    certDir = mkHash hashData;
    keyDir = "key-" + mkHash "${data.acmeServer} ${data.keyType}";

    accountDir = "/var/lib/acme/.lego/accounts/" + mkHash "${data.acmeServer} ${data.keyType}";

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
      # TODO change extraDomains to a regular list
      ++ concatMap (name: [ "-d" name ]) (attrNames data.extraDomains);

    runOpts = escapeShellArgs (commonOpts ++ [ "run" ]);
    renewOpts = escapeShellArgs (
      commonOpts
      ++ [ "renew" "--reuse-key" "--days" (toString cfg.validMinDays) ]
      ++ data.extraLegoRenewFlags
    );

    commonServiceConfig = {
    };
  in nameValuePair serviceName {
    inherit accountDir;

    webroot = data.webroot;
    group = data.group;

    renewTimer = {
      description = "Renew ACME Certificate for ${cert}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.renewInterval;
        Unit = "${serviceName}.service";
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

    renewService = {
      description = "Renew ACME Certificate for ${cert}";
      after = [ "network.target" "network-online.target" ];
      wants = [ "network-online.target" ];

      # https://github.com/NixOS/nixpkgs/pull/81371#issuecomment-605526099
      wantedBy = optionals (!config.boot.isContainer) [ "multi-user.target" ];

      path = with pkgs; [ lego coreutils ];

      serviceConfig = {
        Type = "oneshot";
        User = "acme";
        Group = data.group;
        Umask = 0027;
        StateDirectoryMode = 750;  # With an acme group, do we actually need allowKeysForGroup?
        ProtectSystem = "full";
        PrivateTmp = true;

        # AccountDir dir will be created by systemd to ensure correct permissions
        # And to avoid deletion during systemctl clean
        StateDirectory = "acme/${cert} acme/.lego/${cert}/${certDir} acme/.lego/${cert}/${keyDir}";

        WorkingDirectory = "/tmp";

        BindPaths = ''
          ${accountDir}:/tmp/accounts
          /var/lib/acme/${cert}:/tmp/out
          /var/lib/acme/.lego/${cert}/${certDir}:/tmp/certificates
          /var/lib/acme/.lego/${cert}/${keyDir}:/tmp/keys
        '';

        # Only try loading the credentialsFile if the dns challenge is enabled
        EnvironmentFile = mkIf useDns data.credentialsFile;
      };

      # pwd will be /tmp, which is a tmpfs with the 4 BindPaths configured
      # TODO do we want to keep the directory test for the accounts folder?
      # TODO deal with the fact that most cert files will be owned by root
      # and we won't have permission to fix them
      # TODO Migrate old cert data
      # test ! -d certificates || mv certificates "${certDir}"
      # test ! -d accounts || mv accounts/* "../${accountDir}"
      script = ''
        set -euo pipefail

        # Safely copy keyDir contents into certificates (it might be empty).
        ls -1 keys | xargs -i -- cp -f "keys/{}" "certificates/"

        # Check if we can renew
        if [ -e 'certificates/${keyName}.key' -a -e 'certificates/${keyName}.crt' ]; then
          lego ${renewOpts}

        # Otherwise do a full run
        else
          lego ${runOpts}
        fi

        chmod 640 certificates/* accounts/*

        # Group might change between runs, re-apply it
        chown 'acme:${data.group}' certificates/*

        # Copy the key to keyDir
        cp -pf 'certificates/${keyName}.key' '${keyDir}/'

        # Copy all certs to the "real" certs directory
        CERT='certificates/${keyName}.crt'
        CERT_CHANGED=no
        if [ -e "$CERT" -a "$CERT" -nt out/fullchain.pem ]; then
          CERT_CHANGED=yes
          cp -p 'certificates/${keyName}.crt' out/fullchain.pem
          cp -p 'certificates/${keyName}.key' out/key.pem
          cp -p 'certificates/${keyName}.issuer.crt' out/chain.pem
          ln -sf fullchain.pem out/cert.pem
          cat key.pem fullchain.pem > full.pem
        fi

        if [ "$CERT_CHANGED" = "yes" ]; then
          cd out
          # TODO unset bash options
          ${data.postRun}
        fi
      '';
    };
  };

  certConfigs = mapAttrs certToConfig cfg.certs;

  certOpts = { name, ... }: {
    options = {
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

      user = mkOption {
        type = types.str;
        default = "root";
        description = "User running the ACME client.";
      };

      group = mkOption {
        type = types.str;
        default = "acme";
        description = "Group running the ACME client.";
      };

      allowKeysForGroup = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Give read permissions to the specified group
          (<option>security.acme.cert.&lt;name&gt;.group</option>) to read SSL private certificates.
        '';
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

      extraDomains = mkOption {
        type = types.attrsOf (types.nullOr types.str);
        default = {};
        example = literalExample ''
          {
            "example.org" = null;
            "mydomain.org" = null;
          }
        '';
        description = ''
          A list of extra domain names, which are included in the one certificate to be issued.
          Setting a distinct server root is deprecated and not functional in 20.03+
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

  imports = [
    (mkRemovedOptionModule [ "security" "acme" "production" ] ''
      Use security.acme.server to define your staging ACME server URL instead.

      To use Let's Encrypt's staging server, use security.acme.server =
      "https://acme-staging-v02.api.letsencrypt.org/directory".
    ''
    )
    (mkRemovedOptionModule [ "security" "acme" "directory"] "ACME Directory is now hardcoded to /var/lib/acme and its permisisons are managed by systemd. See https://github.com/NixOS/nixpkgs/issues/53852 for more info.")
    (mkRemovedOptionModule [ "security" "acme" "preDelay"] "This option has been removed. If you want to make sure that something executes before certificates are provisioned, add a RequiredBy=acme-\${cert}.service to the service you want to execute before the cert renewal")
    (mkRemovedOptionModule [ "security" "acme" "activationDelay"] "This option has been removed. If you want to make sure that something executes before certificates are provisioned, add a RequiredBy=acme-\${cert}.service to the service you want to execute before the cert renewal")
    (mkChangedOptionModule [ "security" "acme" "validMin"] [ "security" "acme" "validMinDays"] (config: config.security.acme.validMin / (24 * 3600)))
  ];

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
              extraDomains = { "www.example.com" = null; "foo.example.com" = null; };
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

  config = mkMerge [
    (mkIf (cfg.certs != { }) {

      assertions = let
        certs = attrValues cfg.certs;
      in [
        {
          assertion = all (certOpts: certOpts.dnsProvider == null || certOpts.webroot == null) certs;
          message = ''
            Options `security.acme.certs.<name>.dnsProvider` and
            `security.acme.certs.<name>.webroot` are mutually exclusive.
          '';
        }
        {
          # TODO note here about being consistent with acme email addresses
          assertion = cfg.email != null || all (certOpts: certOpts.email != null) certs;
          message = ''
            You must define `security.acme.certs.<name>.email` or
            `security.acme.email` to register with the CA.
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
      ];

      users.users.acme = {
        uid = config.ids.uids.acme;
        home = "/var/lib/acme";
        group = "acme";
      };

      users.groups.acme.gid = {
        gid = config.ids.gids.acme;
      };

      systemd.services = mapAttrs (cert: conf: conf.renewService) certConfigs;

      systemd.timers = mapAttrs (cert: conf: conf.renewTimer) certConfigs;

      systemd.tmpfiles.rules =
        unique (concatMap (conf: [
            "d ${conf.accountDir} - acme acme"
          ] ++ optional (conf.webroot != null) "d ${data.webroot}/.well-known/acme-challenge - acme ${conf.group}"
        ) (attrValues certConfigs));

      systemd.targets.acme-selfsigned-certificates = mkIf cfg.preliminarySelfsigned {};
      systemd.targets.acme-certificates = {};
    })
  ];

  meta = {
    maintainers = lib.teams.acme.members;
    doc = ./acme.xml;
  };
}
